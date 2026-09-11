/**
 * 服务器监控模块 — 项目类型识别
 *
 * 给定项目目录，根据文件特征判定项目类型。
 * 识别优先级（高→低）：pm2 > systemd > docker > nginx > 自动识别 > 自定义。
 * 这里的 typeDetector 负责「自动识别」部分（不含 pm2/systemd/docker，由 processManager 另查）。
 *
 * 返回：{ type, confidence, signals:[文件名], details:{} }
 */

const fs = require('fs');
const path = require('path');
const { PROJECT_TYPES } = require('./constants');

function hasFile(dir, name) {
  try { return fs.existsSync(path.join(dir, name)); } catch { return false; }
}
function readJson(dir, name) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
  } catch { return null; }
}

/**
 * 检测端口（从常见配置文件中尽力提取）。
 * @param {string} dir
 * @returns {number|null}
 */
function detectPortFromConfig(dir) {
  // SpringBoot application.properties / yml
  for (const f of ['application.properties', 'application.yml', 'application.yaml']) {
    if (hasFile(dir, f)) {
      try {
        const content = fs.readFileSync(path.join(dir, f), 'utf8');
        const m = content.match(/server\.port\s*[:=]\s*(\d+)/i);
        if (m) return parseInt(m[1], 10);
      } catch {}
    }
  }
  return null;
}

/**
 * 识别项目类型。
 * @param {string} dir 项目绝对路径
 * @returns {{type:string, confidence:number, signals:string[], details:object}}
 */
function detect(dir) {
  const signals = [];
  const details = {};

  // ---- Docker Compose ----
  if (hasFile(dir, 'docker-compose.yml') || hasFile(dir, 'docker-compose.yaml')) {
    signals.push('docker-compose.yml');
    return { type: PROJECT_TYPES.DOCKER_COMPOSE, confidence: 1, signals, details };
  }

  // ---- Nginx 站点 ----
  if (hasFile(dir, 'nginx.conf') || hasFile(dir, 'nginx.site.conf') || hasFile(dir, 'default.conf')) {
    signals.push('nginx.conf');
    return { type: PROJECT_TYPES.NGINX_SITE, confidence: 1, signals, details };
  }
  // sites-available 目录
  try {
    const sa = path.join(dir, 'sites-available');
    if (fs.existsSync(sa) && fs.readdirSync(sa).some((f) => f.endsWith('.conf'))) {
      signals.push('sites-available/*.conf');
      return { type: PROJECT_TYPES.NGINX_SITE, confidence: 1, signals, details };
    }
  } catch {}

  // ---- Go ----
  if (hasFile(dir, 'go.mod') && hasFile(dir, 'main.go')) {
    signals.push('go.mod', 'main.go');
    return { type: PROJECT_TYPES.GO, confidence: 1, signals, details };
  }

  // ---- Rust ----
  if (hasFile(dir, 'Cargo.toml')) {
    signals.push('Cargo.toml');
    return { type: PROJECT_TYPES.RUST, confidence: 1, signals, details };
  }

  // ---- .NET ----
  try {
    if (fs.readdirSync(dir).some((f) => f.endsWith('.csproj'))) {
      signals.push('*.csproj');
      return { type: PROJECT_TYPES.DOTNET, confidence: 1, signals, details };
    }
  } catch {}

  // ---- PHP ----
  if (hasFile(dir, 'composer.json')) {
    signals.push('composer.json');
    return { type: PROJECT_TYPES.PHP, confidence: 1, signals, details };
  }

  // ---- SpringBoot ----
  if (hasFile(dir, 'pom.xml') || hasFile(dir, 'build.gradle') || hasFile(dir, 'build.gradle.kts')) {
    signals.push(hasFile(dir, 'pom.xml') ? 'pom.xml' : 'build.gradle');
    const jar = findJar(dir);
    if (jar) details.jarPath = jar;
    details.port = detectPortFromConfig(dir) || 8080;
    return { type: PROJECT_TYPES.SPRINGBOOT, confidence: 1, signals, details };
  }

  // ---- Python ----
  if (hasFile(dir, 'requirements.txt') || hasFile(dir, 'pyproject.toml') || hasFile(dir, 'main.py') || hasFile(dir, 'app.py')) {
    const entry = ['main.py', 'app.py', 'wsgi.py', 'manage.py', 'run.py'].find((f) => hasFile(dir, f));
    if (entry) details.entry = entry;
    signals.push(entry || 'requirements.txt');
    return { type: PROJECT_TYPES.PYTHON, confidence: entry ? 1 : 0.7, signals, details };
  }

  // ---- Node / Vue ----
  const pkg = hasFile(dir, 'package.json') ? readJson(dir, 'package.json') : null;
  if (pkg) {
    const isVue = hasFile(dir, 'vue.config.js') || hasFile(dir, 'vite.config.js') ||
      (pkg.devDependencies && (pkg.devDependencies['@vue/cli-service'] || pkg.devDependencies['vite']));
    signals.push('package.json');
    if (isVue) {
      if (pkg.scripts) {
        details.scripts = pkg.scripts;
      }
      return { type: PROJECT_TYPES.VUE, confidence: 1, signals, details };
    }
    return { type: PROJECT_TYPES.NODE, confidence: 1, signals, details };
  }

  // ---- Shell ----
  const shellScript = ['start.sh', 'run.sh', 'restart.sh', 'stop.sh', 'start.bat', 'run.bat'].find((f) => hasFile(dir, f));
  if (shellScript) {
    signals.push(shellScript);
    return { type: PROJECT_TYPES.SHELL, confidence: 0.9, signals, details };
  }

  // ---- 静态网页 ----
  if (hasFile(dir, 'index.html')) {
    signals.push('index.html');
    return { type: PROJECT_TYPES.STATIC, confidence: 0.8, signals, details };
  }

  return { type: PROJECT_TYPES.UNKNOWN, confidence: 0, signals: [], details: {} };
}

/** 在 target/ 或 build/libs/ 下寻找可运行的 jar 包 */
function findJar(dir) {
  const candidates = [];
  const walk = (d, depth) => {
    if (depth > 4) return;
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(d, e.name);
      if (e.isDirectory()) {
        if (['node_modules', '.git', 'target', 'build'].includes(e.name) && depth > 2) {
          // 仍允许进入 target/build（depth 控制）
        }
        walk(full, depth + 1);
      } else if (e.name.endsWith('.jar') && !e.name.endsWith('-sources.jar') && !e.name.endsWith('-javadoc.jar')) {
        candidates.push(full);
      }
    }
  };
  walk(dir, 0);
  // 优先 target/*.jar
  const targetJar = candidates.find((c) => c.includes(path.sep + 'target' + path.sep));
  return targetJar || candidates[0] || null;
}

module.exports = { detect, detectPortFromConfig, findJar };

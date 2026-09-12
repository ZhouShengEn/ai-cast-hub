/**
 * 服务器监控模块 — 启停脚本自动生成
 *
 * 根据项目类型，自动生成「启动 / 停止 / 重启 / 编译」命令描述。
 * 所有命令以 { bin, args, cwd, env } 数组形式给出，
 * 交给 commandRunner 以无 shell 方式执行，杜绝注入。
 *
 * 支持用户 Web 端覆盖（override）。覆盖时 source 标记为 'custom'。
 *
 * 返回结构：
 * {
 *   type,
 *   source: 'auto' | 'custom',
 *   start:   { bin, args, cwd, env?, note },
 *   stop:    { strategy: 'kill-pid' | 'script', script?: {bin,args,cwd} },
 *   build:   { bin, args, cwd } | null,
 *   port:    number | null,        // 检测到的端口（建议值，用户可改）
 *   notes:   string
 * }
 */

const fs = require('fs');
const path = require('path');
const { PROJECT_TYPES } = require('./constants');
const { findJar } = require('./typeDetector');

/**
 * 生成脚本。
 * @param {object} project { path, type, details }
 * @param {object} [override] 用户自定义覆盖 { type, start, stop, build, port }
 * @returns {object}
 */
function generate(project, override = null) {
  if (override && override.type) {
    // 用户显式指定了类型（未知项目手动选择）
    project = { ...project, type: override.type };
  }

  switch (project.type) {
    case PROJECT_TYPES.NODE:
      return genNode(project, override);
    case PROJECT_TYPES.VUE:
      return genVue(project, override);
    case PROJECT_TYPES.SPRINGBOOT:
      return genSpringboot(project, override);
    case PROJECT_TYPES.PYTHON:
      return genPython(project, override);
    case PROJECT_TYPES.GO:
      return genGo(project, override);
    case PROJECT_TYPES.RUST:
      return genRust(project, override);
    case PROJECT_TYPES.PHP:
      return genPhp(project, override);
    case PROJECT_TYPES.DOTNET:
      return genDotnet(project, override);
    case PROJECT_TYPES.STATIC:
      return genStatic(project, override);
    case PROJECT_TYPES.SHELL:
      return genShell(project, override);
    case PROJECT_TYPES.DOCKER_COMPOSE:
      return genDocker(project, override);
    case PROJECT_TYPES.NGINX_SITE:
      // Nginx 站点由 nginxManager 负责，这里不生成独立启停
      return {
        type: project.type,
        source: 'auto',
        start: null,
        stop: { strategy: 'nginx' },
        build: null,
        port: null,
        notes: 'Nginx 站点项目，由 Nginx 管理模块负责启停与反向代理。',
      };
    default:
      return {
        type: PROJECT_TYPES.UNKNOWN,
        source: 'auto',
        start: null,
        stop: { strategy: 'kill-pid' },
        build: null,
        port: null,
        notes: '未知项目类型，请在 Web 端手动配置启停命令。',
      };
  }
}

function genNode(project, override) {
  const cwd = project.path;
  let scriptName = 'start';
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(cwd, 'package.json'), 'utf8'));
    const scripts = pkg.scripts || {};
    if (scripts.start) scriptName = 'start';
    else if (scripts.serve) scriptName = 'serve';
    else if (scripts.dev) scriptName = 'dev';
    else if (scripts.main) scriptName = null; // 无 start，直接 node
  } catch {}
  const start = scriptName
    ? { bin: 'npm', args: ['run', scriptName], cwd, env: {}, note: `npm run ${scriptName}` }
    : { bin: 'node', args: ['index.js'], cwd, env: {}, note: 'node index.js' };
  return {
    type: project.type, source: 'auto',
    start, stop: { strategy: 'kill-pid' }, build: null,
    port: null, notes: 'Node.js 项目，根据 package.json scripts 自动启动。',
  };
}

function genVue(project, override) {
  const cwd = project.path;
  let scriptName = 'dev';
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(cwd, 'package.json'), 'utf8'));
    const scripts = pkg.scripts || {};
    if (scripts.dev) scriptName = 'dev';
    else if (scripts.serve) scriptName = 'serve';
    else if (scripts.start) scriptName = 'start';
  } catch {}

  // 检测 Vite 开发端口：用于「端口在监听即判定运行中」（即便本模块无运行记录也能识别）。
  // 优先读 vite.config.* 的 server.port，否则回退到 Vite 默认 5173。
  const devPort = detectVitePort(cwd) ?? 5173;

  return {
    type: project.type, source: 'auto',
    start: { bin: 'npm', args: ['run', scriptName], cwd, env: {}, note: `npm run ${scriptName}（开发服务 :${devPort}）` },
    stop: { strategy: 'kill-pid' }, build: { bin: 'npm', args: ['run', 'build'], cwd },
    port: devPort, notes: 'Vue/前端项目，默认拉起开发服务（dev/serve）。生产请改用 build + 静态托管。',
  };
}

/**
 * 从 vite.config.* 中尽力提取 dev server 端口。
 * @param {string} cwd
 * @returns {number|null}
 */
function detectVitePort(cwd) {
  for (const f of ['vite.config.js', 'vite.config.ts', 'vite.config.mjs', 'vite.config.cjs']) {
    try {
      const content = fs.readFileSync(path.join(cwd, f), 'utf8');
      const m = content.match(/server\s*\??\s*[:=]\s*\{[^}]*?port\s*[:=]\s*(\d+)/i)
        || content.match(/port\s*[:=]\s*(\d+)/i);
      if (m) return parseInt(m[1], 10);
    } catch {}
  }
  return null;
}

function genSpringboot(project, override) {
  const cwd = project.path;
  const jar = findJar(cwd) || override?.jarPath;
  if (jar) {
    return {
      type: project.type, source: 'auto',
      start: { bin: 'java', args: ['-jar', jar], cwd, env: {}, note: `java -jar ${path.basename(jar)}` },
      stop: { strategy: 'kill-pid' }, build: { bin: 'mvn', args: ['package', '-DskipTests'], cwd },
      port: project.details?.port || 8080,
      notes: `检测到构建产物 ${path.basename(jar)}，直接运行。`,
    };
  }
  // 无 jar，需先编译
  return {
    type: project.type, source: 'auto',
    start: { bin: 'mvn', args: ['spring-boot:run'], cwd, env: {}, note: 'mvn spring-boot:run（需先构建或未打包运行）' },
    stop: { strategy: 'kill-pid' }, build: { bin: 'mvn', args: ['package', '-DskipTests'], cwd },
    port: project.details?.port || 8080,
    notes: '未找到 jar 包，将直接以 spring-boot:run 运行（建议先编译）。',
  };
}

function genPython(project, override) {
  const cwd = project.path;
  const entry = project.details?.entry || 'main.py';
  return {
    type: project.type, source: 'auto',
    start: { bin: 'python3', args: [entry], cwd, env: {}, note: `python3 ${entry}` },
    stop: { strategy: 'kill-pid' }, build: null,
    port: null, notes: `Python 项目，入口 ${entry}。端口通常在代码内指定。`,
  };
}

function genGo(project, override) {
  const cwd = project.path;
  const binName = path.basename(cwd);
  const builtBin = path.join(cwd, binName);
  const startExists = (() => { try { return fs.existsSync(builtBin); } catch { return false; } })();
  const start = startExists
    ? { bin: builtBin, args: [], cwd, env: {}, note: `运行已编译二进制 ${binName}` }
    : { bin: 'go', args: ['run', '.'], cwd, env: {}, note: 'go run .（未编译，开发模式）' };
  return {
    type: project.type, source: 'auto',
    start, stop: { strategy: 'kill-pid' }, build: { bin: 'go', args: ['build', '-o', binName, '.'], cwd },
    port: null, notes: 'Go 项目，优先运行编译产物，否则 go run。',
  };
}

function genRust(project, override) {
  const cwd = project.path;
  return {
    type: project.type, source: 'auto',
    start: { bin: 'cargo', args: ['run', '--release'], cwd, env: {}, note: 'cargo run --release' },
    stop: { strategy: 'kill-pid' }, build: { bin: 'cargo', args: ['build', '--release'], cwd },
    port: null, notes: 'Rust 项目，使用 cargo run。',
  };
}

function genPhp(project, override) {
  const cwd = project.path;
  const port = override?.port || 8000;
  return {
    type: project.type, source: 'auto',
    start: { bin: 'php', args: ['-S', `0.0.0.0:${port}`], cwd, env: {}, note: `php -S 0.0.0.0:${port}` },
    stop: { strategy: 'kill-pid' }, build: null,
    port, notes: 'PHP 项目，使用内置开发服务器。生产建议使用 php-fpm + Nginx。',
  };
}

function genDotnet(project, override) {
  const cwd = project.path;
  return {
    type: project.type, source: 'auto',
    start: { bin: 'dotnet', args: ['run', '--urls', 'http://0.0.0.0:5000'], cwd, env: {}, note: 'dotnet run' },
    stop: { strategy: 'kill-pid' }, build: { bin: 'dotnet', args: ['build'], cwd },
    port: 5000, notes: '.NET 项目，使用 dotnet run。',
  };
}

function genStatic(project, override) {
  const cwd = project.path;
  const port = override?.port || 8080;
  return {
    type: project.type, source: 'auto',
    start: { bin: 'python3', args: ['-m', 'http.server', String(port)], cwd, env: {}, note: `python3 -m http.server ${port}` },
    stop: { strategy: 'kill-pid' }, build: null,
    port, notes: '静态网页，使用 Python 内置静态服务器托管。',
  };
}

function genShell(project, override) {
  const cwd = project.path;
  const startScript = (() => {
    for (const f of ['start.sh', 'run.sh', 'start.bat', 'run.bat']) {
      if (fs.existsSync(path.join(cwd, f))) return f;
    }
    return null;
  })();
  const stopScript = (() => {
    for (const f of ['stop.sh', 'stop.bat']) {
      if (fs.existsSync(path.join(cwd, f))) return f;
    }
    return null;
  })();
  if (!startScript) {
    return {
      type: project.type, source: 'auto',
      start: null, stop: { strategy: 'kill-pid' }, build: null, port: null,
      notes: '未找到 start.sh/run.sh，无法自动生成启动脚本。',
    };
  }
  return {
    type: project.type, source: 'auto',
    start: { bin: 'sh', args: [startScript], cwd, env: {}, note: `sh ${startScript}` },
    stop: stopScript
      ? { strategy: 'script', script: { bin: 'sh', args: [stopScript], cwd } }
      : { strategy: 'kill-pid' },
    build: null, port: null, notes: 'Shell 脚本项目，调用 start.sh / stop.sh。',
  };
}

function genDocker(project, override) {
  const cwd = project.path;
  return {
    type: project.type, source: 'auto',
    start: { bin: 'docker', args: ['compose', 'up', '-d'], cwd, env: {}, note: 'docker compose up -d' },
    stop: { strategy: 'script', script: { bin: 'docker', args: ['compose', 'down'], cwd } },
    build: { bin: 'docker', args: ['compose', 'build'], cwd },
    port: null, notes: 'Docker Compose 项目。',
  };
}

/**
 * 将用户覆盖应用到生成的脚本（合并）。
 * @param {object} base 生成的脚本
 * @param {object} override { start?, stop?, build?, port?, type? }
 */
function applyOverride(base, override) {
  if (!override) return base;
  const merged = { ...base };
  if (override.start) merged.start = override.start;
  if (override.stop) merged.stop = override.stop;
  if (override.build) merged.build = override.build;
  if (override.port != null) merged.port = override.port;
  if (override.notes) merged.notes = override.notes;
  merged.source = 'custom';
  return merged;
}

module.exports = { generate, applyOverride };

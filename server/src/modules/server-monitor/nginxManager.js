/**
 * 服务器监控模块 — Nginx 管理 + 路由端口联动锁定（重点）
 *
 * 能力：
 *  - 识别项目内自定义 Nginx 配置（nginx.conf / sites-available/*.conf）与系统全局 Nginx
 *  - 配置校验 nginx -t、平滑重载 nginx -s reload、启停重启
 *  - 在线查看 / 编辑配置（保存前强制语法校验）
 *  - 解析 proxy_pass，自动建立「后端端口 ↔ 业务项目」绑定（端口锁定）
 *  - 强制端口锁定约束：锁定服务端口不可随意修改、启动前双重校验
 *  - 双向联动：修改 Nginx 端口同步更新锁定端口；外部修改 MD5 变更告警
 *  - 读取访问 / 错误日志
 *
 * 安全：所有 Nginx 文件读写限制在显式允许路径内（项目目录 / /etc/nginx / /var/log/nginx）。
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('./config');
const projectStore = require('./projectStore');
const commandRunner = require('./commandRunner');
const { encodeProjectId } = require('./ids');
const scanner = require('./scanner');
const logger = require('../../utils/logger');

const LINKS_FILE = path.join(config.DATA_DIR, 'nginxLinks.json');
const NGINX_LOG_PATHS = ['/var/log/nginx/access.log', '/var/log/nginx/error.log'];
const SYSTEM_NGINX_ROOT = '/etc/nginx';

let _links = loadLinks();

function loadLinks() {
  try {
    if (fs.existsSync(LINKS_FILE)) return JSON.parse(fs.readFileSync(LINKS_FILE, 'utf8')) || {};
  } catch {}
  return {};
}
function saveLinks() {
  try { fs.writeFileSync(LINKS_FILE, JSON.stringify(_links, null, 2)); } catch (e) {
    logger.error(`[Monitor] nginx links 保存失败: ${e.message}`);
  }
}

/** 显式允许读写的 Nginx 路径集合（安全边界） */
function isAllowedNginxPath(p) {
  const resolved = path.resolve(p);
  if (resolved.startsWith(SYSTEM_NGINX_ROOT + path.sep) || resolved === SYSTEM_NGINX_ROOT) return true;
  if (NGINX_LOG_PATHS.includes(resolved)) return true;
  // 项目目录内的 nginx 配置
  const cfg = config.get();
  return commandRunner.getSandboxRoots().some((r) => resolved.startsWith(r + path.sep));
}

// ============================================================
// 配置清单
// ============================================================

/**
 * 列出所有可管理的 Nginx 配置文件。
 * @returns {Array<{id,path,name,scope,projectPath?}>}
 */
function listConfigs() {
  const out = [];
  const cfg = config.get();

  // 1) 项目内配置（nginx-site 类型）
  let projects = [];
  try { projects = scanner.scan(); } catch {}
  for (const proj of projects) {
    if (proj.type !== 'nginx-site') continue;
    const files = findProjectNginxFiles(proj.path);
    for (const f of files) {
      out.push({
        id: encodeProjectId(f),
        path: f,
        name: path.basename(f) + (proj.name ? ` (${proj.name})` : ''),
        scope: 'project',
        projectPath: proj.path,
      });
    }
  }

  // 2) 系统全局 Nginx（需开启 useSystemNginx）
  if (cfg.useSystemNginx && fs.existsSync(SYSTEM_NGINX_ROOT)) {
    out.push({ id: encodeProjectId(path.join(SYSTEM_NGINX_ROOT, 'nginx.conf')), path: path.join(SYSTEM_NGINX_ROOT, 'nginx.conf'), name: 'nginx.conf (系统)', scope: 'system' });
    const dirs = ['conf.d', 'sites-enabled'];
    for (const d of dirs) {
      const dir = path.join(SYSTEM_NGINX_ROOT, d);
      if (!fs.existsSync(dir)) continue;
      try {
        for (const f of fs.readdirSync(dir)) {
          if (f.endsWith('.conf')) {
            const fp = path.join(dir, f);
            out.push({ id: encodeProjectId(fp), path: fp, name: `${d}/${f}`, scope: 'system' });
          }
        }
      } catch {}
    }
  }

  // 3) 额外配置的 Nginx 目录
  for (const dir of (cfg.nginxConfigDirs || [])) {
    if (!fs.existsSync(dir)) continue;
    try {
      for (const f of fs.readdirSync(dir)) {
        if (f.endsWith('.conf')) {
          const fp = path.join(dir, f);
          if (isAllowedNginxPath(fp)) out.push({ id: encodeProjectId(fp), path: fp, name: f, scope: 'extra' });
        }
      }
    } catch {}
  }

  return out;
}

function findProjectNginxFiles(dir) {
  const files = [];
  const candidates = ['nginx.conf', 'nginx.site.conf', 'default.conf'];
  for (const c of candidates) {
    const fp = path.join(dir, c);
    if (fs.existsSync(fp)) files.push(fp);
  }
  const sa = path.join(dir, 'sites-available');
  if (fs.existsSync(sa)) {
    try { for (const f of fs.readdirSync(sa)) if (f.endsWith('.conf')) files.push(path.join(sa, f)); } catch {}
  }
  return files;
}

function getConfig(id) {
  const all = listConfigs();
  const item = all.find((c) => c.id === id);
  if (!item) throw new Error('配置文件不存在或未授权');
  if (!isAllowedNginxPath(item.path)) throw new Error('配置文件越权');
  return item;
}

function getConfigContent(id) {
  const item = getConfig(id);
  const content = fs.readFileSync(item.path, 'utf8');
  const md5 = crypto.createHash('md5').update(content).digest('hex');
  return { ...item, content, md5 };
}

/**
 * 保存配置内容（保存前强制语法校验）。
 * @param {string} id
 * @param {string} content
 * @returns {Promise<{ok:boolean, md5:string, testOutput?:string, error?:string}>}
 */
async function saveConfigContent(id, content) {
  const item = getConfig(id);
  // 先写临时文件做校验
  const tmp = item.path + '.monitor.tmp';
  fs.writeFileSync(tmp, content, 'utf8');
  const testResult = await testConfigWith(tmp, item.path);
  if (!testResult.ok) {
    fs.unlinkSync(tmp);
    return { ok: false, md5: null, testOutput: testResult.output, error: 'Nginx 配置语法校验未通过，已拒绝保存。' };
  }
  // 校验通过，覆盖原文件
  fs.writeFileSync(item.path, content, 'utf8');
  try { fs.unlinkSync(tmp); } catch {}
  const md5 = crypto.createHash('md5').update(content).digest('hex');
  logger.info(`[Monitor] Nginx 配置已保存: ${item.path}`);
  return { ok: true, md5, testOutput: testResult.output };
}

/**
 * 用临时文件校验 Nginx 配置语法。
 * 优先调用 nginx -t；若不可用则退化为正则基础校验。
 */
async function testConfigWith(tmpFile, origFile) {
  try {
    const r = await commandRunner.run({ bin: 'nginx', args: ['-t', '-c', tmpFile] }, {}, 15000);
    const output = (r.stdout + r.stderr).trim();
    // nginx -t 成功时退出码 0 且包含 "test is successful" 或 "syntax is ok"
    const ok = r.code === 0 && /successful|syntax is ok/i.test(output);
    return { ok, output };
  } catch (e) {
    // nginx 不可用（如开发机），退化为本地正则校验
    return fallbackValidate(tmpFile);
  }
}

/** 基础语法校验（平衡括号、proxy_pass 合法性） */
function fallbackValidate(file) {
  try {
    const content = fs.readFileSync(file, 'utf8');
    const open = (content.match(/{/g) || []).length;
    const close = (content.match(/}/g) || []).length;
    let output = `括号匹配: { ${open} / } ${close}\n`;
    let ok = true;
    if (open !== close) { ok = false; output += '错误：大括号不匹配\n'; }
    if (/proxy_pass\s+http:\/\/[^;\s]+/i.test(content) === false && /proxy_pass/.test(content)) {
      ok = false; output += '警告：proxy_pass 语法异常\n';
    }
    return { ok, output };
  } catch (e) {
    return { ok: false, output: '读取文件失败: ' + e.message };
  }
}

/** 全局校验（nginx -t，使用系统主配置） */
async function testConfig() {
  try {
    const r = await commandRunner.run({ bin: 'nginx', args: ['-t'] }, {}, 15000);
    return { ok: r.code === 0, output: (r.stdout + r.stderr).trim() };
  } catch (e) {
    return fallbackValidate(SYSTEM_NGINX_ROOT + '/nginx.conf');
  }
}

async function reload() {
  // 先校验
  const t = await testConfig();
  if (!t.ok) return { ok: false, message: '校验未通过，已阻止重载:\n' + t.output };
  try {
    const r = await commandRunner.run({ bin: 'nginx', args: ['-s', 'reload'] }, {}, 15000);
    return { ok: r.code === 0, message: (r.stdout + r.stderr).trim() || '重载成功' };
  } catch (e) {
    return { ok: false, message: '重载失败: ' + e.message };
  }
}

async function nginxControl(action) {
  if (!['start', 'stop', 'restart'].includes(action)) throw new Error('非法操作');
  const tryCmds = [
    { bin: 'systemctl', args: [action, 'nginx'] },
    { bin: 'service', args: ['nginx', action] },
  ];
  if (action === 'stop') tryCmds.push({ bin: 'nginx', args: ['-s', 'stop'] });
  if (action === 'start') tryCmds.push({ bin: 'nginx', args: [] });
  for (const c of tryCmds) {
    try {
      const r = await commandRunner.run(c, {}, 15000);
      if (r.code === 0) return { ok: true, message: `nginx ${action} 成功` };
    } catch (_) {}
  }
  return { ok: false, message: `nginx ${action} 失败（可能需要 root 权限或 nginx 未安装）` };
}

/** 读取 Nginx 日志（访问 / 错误） */
async function getLogs(type = 'error', lines = 200) {
  const file = type === 'access' ? NGINX_LOG_PATHS[0] : NGINX_LOG_PATHS[1];
  if (!fs.existsSync(file)) return { ok: false, message: `日志文件不存在: ${file}`, content: '' };
  try {
    const util = require('./util');
    const content = await util.readTail(file, lines);
    return { ok: true, content };
  } catch (e) {
    return { ok: false, message: e.message, content: '' };
  }
}

// ============================================================
// 路由端口联动锁定
// ============================================================

/**
 * 解析 Nginx 配置中的 proxy_pass 与 server_name。
 * @returns {Array<{proxyPass:string, port:number, serverName:string, listenPort:number|null}>}
 */
function parseProxyPass(content) {
  const results = [];
  const blocks = content.split(/server\s*{/);
  for (const block of blocks.slice(1)) {
    const serverNameM = block.match(/server_name\s+([^;]+);/);
    const serverName = serverNameM ? serverNameM[1].trim().replace(/;/g, '') : '';
    const listenM = block.match(/listen\s+(\d+)/);
    const listenPort = listenM ? Number(listenM[1]) : null;
    const proxyM = block.match(/proxy_pass\s+https?:\/\/([^;\s]+)/);
    if (proxyM) {
      const host = proxyM[1];
      const portM = host.match(/:(\d+)/);
      const port = portM ? Number(portM[1]) : 80;
      results.push({ proxyPass: proxyM[0].trim(), port, serverName, listenPort });
    }
  }
  return results;
}

/**
 * 扫描全部 Nginx 配置，建立/刷新端口绑定关系。
 * 自动将「后端端口 == proxy_pass 端口」的项目与 Nginx 配置关联（打标签 + 端口锁定）。
 * @returns {Array} 当前所有 link
 */
function rebuildLinks() {
  const configs = listConfigs();
  const newLinks = {};

  for (const cfg of configs) {
    let content;
    try { content = fs.readFileSync(cfg.path, 'utf8'); } catch { continue; }
    const md5 = crypto.createHash('md5').update(content).digest('hex');
    const proxies = parseProxyPass(content);
    for (const p of proxies) {
      const linkId = crypto.createHash('md5').update(cfg.path + ':' + p.port).digest('hex').slice(0, 16);
      newLinks[linkId] = {
        id: linkId,
        configId: cfg.id,
        configFile: cfg.path,
        proxyPort: p.port,
        serverName: p.serverName,
        listenPort: p.listenPort,
        scope: cfg.scope,
        md5,
        createdAt: _links[linkId]?.createdAt || new Date().toISOString(),
      };
    }
  }

  _links = newLinks;
  saveLinks();

  // 自动关联：将端口匹配的项目与 link 绑定
  autoAssociate();
  return Object.values(_links);
}

/** 自动关联：端口相同的项目与 Nginx link 绑定 */
function autoAssociate() {
  let projects = [];
  try { projects = scanner.scan(); } catch {}
  for (const link of Object.values(_links)) {
    // 找端口匹配且未锁定的项目
    for (const proj of projects) {
      const override = projectStore.getOverrides(proj.path);
      if (override.nginxLinkId) continue; // 已关联
      const script = (() => { try { return require('./scriptGenerator').generate(proj); } catch { return null; } })();
      const port = override.port != null ? Number(override.port) : (script && script.port);
      if (port && port === link.proxyPort) {
        projectStore.setOverride(proj.path, { nginxLinkId: link.id, port: link.proxyPort });
        link.projectPath = proj.path;
      }
    }
  }
}

function getLinks() {
  return Object.values(_links).map((l) => {
    const proj = l.projectPath ? findProjectByPath(l.projectPath) : null;
    return { ...l, projectName: proj?.name || null };
  });
}

function getLink(linkId) {
  return _links[linkId] || null;
}

/** 手动关联：指定项目与某 Nginx 配置（按端口）绑定 */
function setLink(projectPath, configId, port) {
  const cfg = getConfig(configId);
  if (!cfg) throw new Error('Nginx 配置文件不存在');
  const linkId = crypto.createHash('md5').update(cfg.path + ':' + port).digest('hex').slice(0, 16);
  _links[linkId] = {
    id: linkId,
    configId,
    configFile: cfg.path,
    proxyPort: Number(port),
    serverName: '',
    listenPort: null,
    scope: cfg.scope,
    md5: crypto.createHash('md5').update(fs.readFileSync(cfg.path, 'utf8')).digest('hex'),
    createdAt: _links[linkId]?.createdAt || new Date().toISOString(),
    projectPath,
  };
  saveLinks();
  projectStore.setOverride(projectPath, { nginxLinkId: linkId, port: Number(port) });
  return _links[linkId];
}

function removeLink(linkId) {
  const link = _links[linkId];
  if (!link) throw new Error('关联不存在');
  // 清理项目上的绑定
  if (link.projectPath) {
    const ov = projectStore.getOverrides(link.projectPath);
    if (ov.nginxLinkId === linkId) projectStore.setOverride(link.projectPath, { nginxLinkId: null });
  }
  delete _links[linkId];
  saveLinks();
  return true;
}

function findProjectByPath(p) {
  try {
    return scanner.scan().find((x) => x.path === p);
  } catch { return null; }
}

/** 检测 link 配置文件 MD5 是否变化（外部修改告警用） */
function detectConfigChanges() {
  const changed = [];
  for (const link of Object.values(_links)) {
    try {
      const content = fs.readFileSync(link.configFile, 'utf8');
      const md5 = crypto.createHash('md5').update(content).digest('hex');
      if (md5 !== link.md5) {
        link.md5 = md5;
        changed.push(link);
      }
    } catch {}
  }
  if (changed.length) saveLinks();
  return changed;
}

/**
 * 为某 Nginx 配置生成静态站点模板（用于静态项目一键托管）。
 */
function generateStaticTemplate(serverName, port, rootPath) {
  return `server {
    listen 80;
    server_name ${serverName};

    location / {
        root ${rootPath};
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    # 反向代理示例（如需代理到后端服务，取消注释并修改端口）
    # location /api/ {
    #     proxy_pass http://127.0.0.1:${port};
    #     proxy_set_header Host $host;
    #     proxy_set_header X-Real-IP $remote_addr;
    # }
}
`;
}

module.exports = {
  listConfigs,
  getConfigContent,
  saveConfigContent,
  testConfig,
  reload,
  nginxControl,
  getLogs,
  parseProxyPass,
  rebuildLinks,
  getLinks,
  getLink,
  setLink,
  removeLink,
  detectConfigChanges,
  generateStaticTemplate,
  isAllowedNginxPath,
};

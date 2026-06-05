/**
 * 统一 AI 适配器
 *
 * - 根据 model 标识 (格式: {provider}:{modelName}) 路由到对应 Provider
 * - 提供统一的流式/非流式对话接口
 * - 初始化时加载所有可用 Provider 实例
 */

const logger = require('../../utils/logger');
const cryptoService = require('../cryptoService');
const ApiKeyModel = require('../../models/ApiKey');

// Provider 构造器映射
const providerConstructors = {
  openai: require('./providers/openai'),
  claude: require('./providers/claude'),
  gemini: require('./providers/gemini'),
  qwen: require('./providers/qwen'),
  ernie: require('./providers/ernie'),
  deepseek: require('./providers/deepseek'),
  glm: require('./providers/glm'),
};

/** @type {Map<string, object>} provider 名称 → Provider 实例 */
const providerInstances = new Map();

/**
 * 初始化所有 Provider 实例
 * 从数据库加载已配置的 API Key，为每个 provider 创建实例
 * @returns {Promise<void>}
 */
async function initializeProviders() {
  try {
    // 遍历所有已知 provider，从数据库查询对应的 API Key
    for (const [providerName, Constructor] of Object.entries(providerConstructors)) {
      try {
        const keyRecord = await ApiKeyModel.findByProvider(providerName);
        if (!keyRecord) {
          logger.debug(`[AI Adapter] Provider "${providerName}" 未配置 API Key，将在运行时跳过`);
          continue;
        }
        const decryptedKey = cryptoService.decryptApiKey(keyRecord.encrypted_key);
        const instance = new Constructor({ apiKey: decryptedKey });
        providerInstances.set(providerName, instance);
        logger.info(`[AI Adapter] Provider "${providerName}" 已初始化`);
      } catch (err) {
        logger.warn(`[AI Adapter] Provider "${providerName}" 初始化失败: ${err.message}`);
      }
    }

    logger.info(`[AI Adapter] 已初始化 ${providerInstances.size} 个 Provider`);
  } catch (err) {
    logger.warn(`[AI Adapter] 初始化 Providers 失败（可能数据库未就绪）: ${err.message}`);
  }
}

/**
 * 根据 model 标识解析 provider 和 modelName
 * 格式: "openai:gpt-4o" → { provider: "openai", modelName: "gpt-4o" }
 * @param {string} modelId - 模型标识
 * @returns {{ provider: string, modelName: string }}
 */
function parseModelId(modelId) {
  const colonIdx = modelId.indexOf(':');
  if (colonIdx === -1) {
    // 默认当作 openai 处理
    return { provider: 'openai', modelName: modelId };
  }
  return {
    provider: modelId.substring(0, colonIdx),
    modelName: modelId.substring(colonIdx + 1),
  };
}

/**
 * 按 provider 名称获取 Provider 实例
 * @param {string} providerName - Provider 名称
 * @returns {object|null} Provider 实例或 null
 */
function route(providerName) {
  const instance = providerInstances.get(providerName);
  if (!instance) {
    logger.warn(`[AI Adapter] Provider "${providerName}" 不可用`);
    return null;
  }
  return instance;
}

/**
 * 流式对话（AsyncGenerator）
 * @param {Array<object>} messages - 消息数组 [{role, content}]
 * @param {object} options - { model, max_tokens, temperature }
 * @returns {AsyncGenerator<string>} token 生成器
 */
async function* chat(messages, options = {}) {
  const modelId = options.model || 'openai:gpt-3.5-turbo';
  const { provider: providerName, modelName } = parseModelId(modelId);

  const provider = route(providerName);
  if (!provider) {
    throw new Error(`Provider "${providerName}" 不可用，请先配置对应的 API Key`);
  }

  const chatOptions = { ...options, model: modelName };
  yield* provider.chat(messages, chatOptions);
}

/**
 * 非流式对话
 * @param {Array<object>} messages - 消息数组
 * @param {object} options - { model, max_tokens, temperature }
 * @returns {Promise<string>} 完整响应内容
 */
async function chatSync(messages, options = {}) {
  const modelId = options.model || 'openai:gpt-3.5-turbo';
  const { provider: providerName, modelName } = parseModelId(modelId);

  const provider = route(providerName);
  if (!provider) {
    throw new Error(`Provider "${providerName}" 不可用，请先配置对应的 API Key`);
  }

  const chatOptions = { ...options, model: modelName };
  return provider.chatSync(messages, chatOptions);
}

/**
 * 计数 Token
 * @param {Array<object>} messages - 消息数组
 * @param {string} modelId - 模型标识
 * @returns {Promise<number>} token 数量
 */
async function countTokens(messages, modelId) {
  const { provider: providerName } = parseModelId(modelId);
  const provider = route(providerName);
  if (!provider) {
    // 降级估算
    let totalChars = 0;
    for (const msg of messages) {
      totalChars += (msg.content || '').length;
    }
    return Math.ceil(totalChars / 4);
  }
  return provider.countTokens(messages, modelId);
}

/**
 * 获取当前已配置的所有 Provider 实例
 * @returns {Map<string, object>}
 */
function getProviderInstances() {
  return providerInstances;
}

/**
 * 动态添加/刷新 Provider 实例（当 API Key 被配置后）
 * @param {string} providerName - Provider 名称
 * @param {string} apiKey - API Key 明文
 */
function refreshProvider(providerName, apiKey) {
  const Constructor = providerConstructors[providerName];
  if (!Constructor) {
    throw new Error(`未知 Provider: ${providerName}`);
  }
  const instance = new Constructor({ apiKey });
  providerInstances.set(providerName, instance);
  logger.info(`[AI Adapter] Provider "${providerName}" 已刷新`);
}

/**
 * 获取所有可用模型列表（从所有已配置 Provider 聚合）
 * @returns {Array<{provider: string, models: Array<string>}>}
 */
/** 各 Provider 的已知模型列表（无需实例化即可获取） */
const STATIC_MODEL_LISTS = {
  openai: ['gpt-4o', 'gpt-4-turbo', 'gpt-3.5-turbo'],
  claude: ['claude-3-5-sonnet-20241022', 'claude-3-opus-20240229'],
  gemini: ['gemini-1.5-pro', 'gemini-1.5-flash'],
  qwen: ['qwen-plus', 'qwen-max', 'qwen-turbo', 'qwen-plus-latest'],
  ernie: ['ernie-4.0-8k', 'ernie-3.5-8k', 'ernie-speed-8k', 'ernie-lite-8k'],
  deepseek: ['deepseek-chat', 'deepseek-coder'],
  glm: ['glm-4', 'glm-4-flash'],
};

function getAllModels() {
  const result = [];
  for (const [name, models] of Object.entries(STATIC_MODEL_LISTS)) {
    result.push({
      provider: name,
      models,
      configured: providerInstances.has(name),
    });
  }
  return result;
}

module.exports = {
  initializeProviders,
  route,
  chat,
  chatSync,
  countTokens,
  getProviderInstances,
  refreshProvider,
  getAllModels,
  parseModelId,
};

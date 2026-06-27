/**
 * 文心一言 (ERNIE) Provider — 百度千帆
 *
 * 支持两种认证模式:
 * 1. 直接 Bearer Token: 用户提供 access_token
 * 2. API Key + Secret Key: 格式 "client_id:client_secret"，自动换取 access_token
 *
 * apiEndpoint: https://qianfan.baidubce.com/v2/chat/completions
 */

const OpenAI = require('openai');
const ProviderBase = require('../providerBase');
const logger = require('../../../utils/logger');

class ErnieProvider extends ProviderBase {
  constructor({ apiKey }) {
    super({
      apiEndpoint: 'https://qianfan.baidubce.com/v2/chat/completions',
      apiKey,
    });

    // 如果是 client_id:client_secret 格式，需要换取 access_token
    if (apiKey && apiKey.includes(':') && !apiKey.startsWith('eyJ') && !apiKey.startsWith('24.')) {
      this._clientId = apiKey.split(':')[0];
      this._clientSecret = apiKey.split(':').slice(1).join(':');
      this._accessToken = null;
      this._tokenExpiry = 0;
      // 初始化时先不获取 token，延迟到首次调用
      this.apiKey = ''; // 暂不设置，等获取 access_token
    } else {
      // 直接使用 Bearer token
      this._accessToken = apiKey;
      this._tokenExpiry = Infinity;
      this._clientId = null;
      this._clientSecret = null;
    }

    // 创建 client 时会用 this.apiKey，OAuth 模式下在 _ensureToken 中重设
    this.client = null;
    this._ensureClient();
  }

  _ensureClient() {
    if (this.client && this.apiKey) return;
    if (!this.apiKey) return; // OAuth 还没获取到 token
    this.client = new OpenAI({
      apiKey: this.apiKey,
      baseURL: 'https://qianfan.baidubce.com/v2',
    });
  }

  /**
   * 通过 client_id + client_secret 换取 access_token
   */
  async _ensureToken() {
    if (!this._clientId || !this._clientSecret) {
      // 非 OAuth 模式，直接返回
      return;
    }

    // 检查 token 是否过期（提前 5 分钟刷新）
    if (this._accessToken && Date.now() < this._tokenExpiry - 5 * 60 * 1000) {
      return;
    }

    try {
      const params = new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: this._clientId,
        client_secret: this._clientSecret,
      });

      const resp = await fetch(`https://aip.baidubce.com/oauth/2.0/token?${params.toString()}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      });

      const body = await resp.json();

      if (body.access_token) {
        this._accessToken = body.access_token;
        this._tokenExpiry = Date.now() + (body.expires_in || 2592000) * 1000;
        this.apiKey = this._accessToken;
        this._ensureClient();
        logger.info('[ERNIE] OAuth access_token 已获取');
      } else {
        throw new Error(`获取 access_token 失败: ${body.error_description || body.error || '未知错误'}`);
      }
    } catch (err) {
      logger.error(`[ERNIE] OAuth token 获取失败: ${err.message}`);
      throw new Error(`百度千帆 OAuth 认证失败: ${err.message}`);
    }
  }

  buildHeaders() {
    return {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${this.apiKey}`,
    };
  }

  /**
   * 流式对话
   */
  async *chat(messages, options = {}) {
    const model = options.model || 'ernie-4.0-8k';

    try {
      await this._ensureToken();

      const stream = await this.client.chat.completions.create({
        model,
        messages,
        stream: true,
        max_tokens: options.max_tokens || 4096,
        temperature: options.temperature !== undefined ? options.temperature : 0.7,
      });

      for await (const chunk of stream) {
        const content = chunk.choices?.[0]?.delta?.content;
        if (content) {
          yield content;
        }
      }
    } catch (err) {
      logger.error(`[ERNIE] 流式调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * 非流式对话
   */
  async chatSync(messages, options = {}) {
    const model = options.model || 'ernie-4.0-8k';

    try {
      await this._ensureToken();

      const response = await this.client.chat.completions.create({
        model,
        messages,
        stream: false,
        max_tokens: options.max_tokens || 4096,
        temperature: options.temperature !== undefined ? options.temperature : 0.7,
      });
      return response.choices?.[0]?.message?.content || '';
    } catch (err) {
      logger.error(`[ERNIE] 同步调用失败: ${err.message}`);
      throw err;
    }
  }

  getModels() {
    return ['ernie-4.0-8k', 'ernie-3.5-8k', 'ernie-speed-8k', 'ernie-lite-8k'];
  }
}

module.exports = ErnieProvider;

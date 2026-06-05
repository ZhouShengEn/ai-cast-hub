/**
 * Gemini (Google) Provider
 *
 * 使用 @google/generative-ai SDK 调用 Gemini API。
 * 需要将 OpenAI 格式的 messages 转换为 Gemini 格式。
 */

const { GoogleGenerativeAI } = require('@google/generative-ai');
const ProviderBase = require('../providerBase');
const logger = require('../../../utils/logger');

class GeminiProvider extends ProviderBase {
  constructor({ apiKey }) {
    super({
      apiEndpoint: 'https://generativelanguage.googleapis.com/v1beta',
      apiKey,
    });
    this.genAI = new GoogleGenerativeAI(apiKey);
  }

  /**
   * 将 OpenAI 格式消息转为 Gemini 格式
   * @param {Array<object>} messages
   * @returns {{ systemInstruction: string|null, history: Array<object>, lastMessage: string }}
   */
  _convertMessages(messages) {
    let systemInstruction = null;
    const history = [];
    let lastMessage = '';

    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i];
      if (msg.role === 'system') {
        systemInstruction = msg.content;
        continue;
      }

      const geminiRole = msg.role === 'assistant' ? 'model' : 'user';

      if (i === messages.length - 1 && geminiRole === 'user') {
        lastMessage = msg.content;
      } else {
        history.push({
          role: geminiRole,
          parts: [{ text: msg.content }],
        });
      }
    }

    return { systemInstruction, history, lastMessage };
  }

  /**
   * 流式对话
   * @param {Array<object>} messages
   * @param {object} options
   * @returns {AsyncGenerator<string>}
   */
  async *chat(messages, options = {}) {
    const modelName = options.model || 'gemini-1.5-pro';
    const { systemInstruction, history, lastMessage } = this._convertMessages(messages);

    try {
      const model = this.genAI.getGenerativeModel({
        model: modelName,
        systemInstruction: systemInstruction || undefined,
      });

      const chat = model.startChat({ history });
      const result = await chat.sendMessageStream(lastMessage);

      for await (const chunk of result.stream) {
        const text = chunk.text();
        if (text) {
          yield text;
        }
      }
    } catch (err) {
      logger.error(`[Gemini] 流式调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * 非流式对话
   * @param {Array<object>} messages
   * @param {object} options
   * @returns {Promise<string>}
   */
  async chatSync(messages, options = {}) {
    const modelName = options.model || 'gemini-1.5-pro';
    const { systemInstruction, history, lastMessage } = this._convertMessages(messages);

    try {
      const model = this.genAI.getGenerativeModel({
        model: modelName,
        systemInstruction: systemInstruction || undefined,
      });

      const chat = model.startChat({ history });
      const result = await chat.sendMessage(lastMessage);
      return result.response.text();
    } catch (err) {
      logger.error(`[Gemini] 同步调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * Token 计数
   * @param {Array<object>} messages
   * @param {string} model
   * @returns {Promise<number>}
   */
  async countTokens(messages, model = 'gemini-1.5-pro') {
    try {
      const { systemInstruction, history, lastMessage } = this._convertMessages(messages);
      const geminiModel = this.genAI.getGenerativeModel({ model });

      const allParts = history.flatMap(h => h.parts);
      allParts.push({ text: lastMessage });

      const result = await geminiModel.countTokens({
        contents: [{ role: 'user', parts: allParts }],
      });
      return result.totalTokens;
    } catch {
      let totalChars = 0;
      for (const msg of messages) {
        totalChars += (msg.content || '').length;
      }
      return Math.ceil(totalChars / 4);
    }
  }

  /**
   * 返回支持的模型列表
   * @returns {Array<string>}
   */
  getModels() {
    return ['gemini-1.5-pro', 'gemini-1.5-flash'];
  }
}

module.exports = GeminiProvider;

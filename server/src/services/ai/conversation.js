/**
 * 对话管理服务
 *
 * 封装完整的对话生命周期管理:
 * - 创建对话 → 发送消息(流式) → 存储AI回复 → 记录Token用量
 */

const logger = require('../../utils/logger');
const ConversationModel = require('../../models/Conversation');
const MessageModel = require('../../models/Message');
const TokenUsageModel = require('../../models/TokenUsage');
const adapter = require('./adapter');

/**
 * 解析模型标识为 provider + modelName
 * @param {string} modelId - 格式: "openai:gpt-4o"
 * @returns {{ provider: string, modelName: string }}
 */
function parseModel(modelId) {
  const colonIdx = modelId.indexOf(':');
  if (colonIdx === -1) {
    return { provider: 'openai', modelName: modelId };
  }
  return {
    provider: modelId.substring(0, colonIdx),
    modelName: modelId.substring(colonIdx + 1),
  };
}

/**
 * 创建新对话
 * @param {string} deviceId - 设备 UUID
 * @param {string} model - 模型标识 (如 "openai:gpt-4o")
 * @returns {Promise<object>} 创建的对话对象
 */
async function createConversation(deviceId, model) {
  const { provider, modelName } = parseModel(model);
  const conv = await ConversationModel.create(deviceId, provider, modelName, '新对话');
  logger.info(`[Conversation] 新对话 #${conv.id} 设备=${deviceId} 模型=${model}`);
  return conv;
}

/**
 * 发送消息（流式 AsyncGenerator）
 * @param {number} convId - 对话 ID
 * @param {string} content - 用户消息内容
 * @param {string} model - 模型标识
 * @returns {AsyncGenerator<{type: string, token?: string, error?: string, done?: boolean, usage?: object}>}
 */
async function* sendMessage(convId, content, model) {
  const { provider, modelName } = parseModel(model);
  const fullModelId = model.includes(':') ? model : `openai:${model}`;

  // 1. 存储用户消息
  await MessageModel.create(convId, 'user', content, {
    modelName: fullModelId,
  });

  // 2. 获取历史消息（最近20条）
  const history = await MessageModel.findByConversation(convId, 20);

  // 3. 构造消息数组（只包含 role + content）
  const messages = history.map(msg => ({
    role: msg.role,
    content: msg.content,
  }));

  // 估算输入 token
  const inputTokens = await adapter.countTokens(messages, fullModelId);

  // 4. 流式调用 AI
  let fullResponse = '';
  let errorOccurred = false;

  try {
    for await (const token of adapter.chat(messages, { model: fullModelId })) {
      fullResponse += token;
      yield { type: 'token', token };
    }
  } catch (err) {
    errorOccurred = true;
    logger.error(`[Conversation] AI 调用失败 convId=${convId}: ${err.message}`);
    yield { type: 'error', error: err.message };
    return;
  }

  if (errorOccurred) {
    return;
  }

  // 5. 估算输出 token
  const outputTokens = Math.ceil(fullResponse.length / 4);

  // 6. 存储 AI 回复
  const aiMessage = await MessageModel.create(convId, 'assistant', fullResponse, {
    modelName: fullModelId,
    inputTokens,
    outputTokens,
  });

  // 7. 获取对话所属设备 ID 并记录 token 用量
  try {
    const conversation = await ConversationModel.findById(convId);
    if (conversation) {
      await TokenUsageModel.record(
        conversation.device_id,
        modelName,
        provider,
        inputTokens,
        outputTokens
      );
    }
  } catch (err) {
    logger.warn(`[Conversation] Token 用量记录失败: ${err.message}`);
  }

  // 8. 发送完成信号
  yield {
    type: 'done',
    done: true,
    usage: {
      inputTokens,
      outputTokens,
      totalTokens: inputTokens + outputTokens,
      model: fullModelId,
    },
  };
}

/**
 * 获取对话消息历史
 * @param {number} convId - 对话 ID
 * @returns {Promise<Array<object>>} 消息列表
 */
async function getHistory(convId) {
  return MessageModel.findByConversation(convId, 50);
}

/**
 * 删除对话及所有消息
 * @param {number} convId - 对话 ID
 * @returns {Promise<boolean>} 是否删除成功
 */
async function deleteConversation(convId) {
  // 先删除消息
  await MessageModel.deleteByConversation(convId);
  // 再删除对话
  const result = await ConversationModel.deleteById(convId);
  logger.info(`[Conversation] 对话 #${convId} 已删除`);
  return result;
}

/**
 * 分页查询设备对话列表
 * @param {string} deviceId - 设备 UUID
 * @param {number} [limit=20] - 每页数量
 * @param {number} [offset=0] - 偏移量
 * @returns {Promise<{list: Array<object>, total: number}>} 分页结果
 */
async function listConversations(deviceId, limit = 20, offset = 0) {
  const [list, total] = await Promise.all([
    ConversationModel.findByDevice(deviceId, limit, offset),
    ConversationModel.countByDevice(deviceId),
  ]);
  return { list, total };
}

module.exports = {
  createConversation,
  sendMessage,
  getHistory,
  deleteConversation,
  listConversations,
};

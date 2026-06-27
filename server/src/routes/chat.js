/**
 * AI 对话路由
 *
 * POST /send               — 发送消息（SSE 流式响应）
 * GET  /conversations      — 对话列表（分页）
 * GET  /conversation/:id/messages — 消息历史
 * DELETE /conversation/:id — 删除对话
 */

const { Router } = require('express');
const { chatSendSchema } = require('../utils/validators');
const conversationService = require('../services/ai/conversation');
const ConversationModel = require('../models/Conversation');
const logger = require('../utils/logger');

const router = Router();

/**
 * POST /api/v1/chat/send
 * 发送消息 — SSE 流式响应
 * Body: { conversationId?, content, model }
 */
router.post('/send', async (req, res, next) => {
  try {
    const { conversationId, content, model } = chatSendSchema.parse(req.body);

    // 设置 SSE 响应头
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no'); // 禁用 nginx 缓冲

    // 300s 超时
    req.setTimeout(300000);
    res.setTimeout(300000);

    let convId = conversationId;

    // 如无 conversationId → 创建新对话
    if (!convId) {
      const conv = await conversationService.createConversation(
        req.deviceUuid,
        model
      );
      convId = conv.id;

      // 发送 conversation_created 事件
      res.write(`data: ${JSON.stringify({ type: 'conversation_created', conversationId: convId })}\n\n`);
    }

    // 验证对话归属
    const conv = await ConversationModel.findById(convId);
    if (!conv) {
      res.write(`data: ${JSON.stringify({ type: 'error', error: '对话不存在' })}\n\n`);
      res.write('data: [DONE]\n\n');
      return res.end();
    }

    // 流式发送
    let totalOutputTokens = 0;
    try {
      for await (const event of conversationService.sendMessage(convId, content, model)) {
        if (event.type === 'token') {
          res.write(`data: ${JSON.stringify({ token: event.token })}\n\n`);
        } else if (event.type === 'done') {
          totalOutputTokens = event.usage?.outputTokens || 0;
          res.write(`data: ${JSON.stringify({ type: 'done', usage: event.usage })}\n\n`);
        } else if (event.type === 'error') {
          res.write(`data: ${JSON.stringify({ type: 'error', error: event.error })}\n\n`);
        }
      }
    } catch (streamErr) {
      logger.error(`[Chat] SSE 流错误: ${streamErr.message}`);
      res.write(`data: ${JSON.stringify({ type: 'error', error: streamErr.message })}\n\n`);
    }

    // Token 用量已在 conversationService.sendMessage 内部记录，此处无需重复记录

    res.write('data: [DONE]\n\n');
    res.end();
  } catch (err) {
    // 如果还没设置 SSE 头，则返回普通 JSON 错误
    if (!res.headersSent) {
      next(err);
    } else {
      res.write(`data: ${JSON.stringify({ type: 'error', error: err.message })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    }
  }
});

/**
 * POST /api/v1/chat/conversations
 * 创建空对话（返回 JSON，非 SSE）
 * Body: { model }
 */
router.post('/conversations', async (req, res, next) => {
  try {
    const { model } = req.body;
    if (!model) {
      return res.status(400).json({ code: 400, data: null, message: 'model 不能为空' });
    }
    const conv = await conversationService.createConversation(req.deviceUuid, model);
    res.json({ code: 0, data: conv, message: 'ok' });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/chat/conversations
 * 获取对话列表
 * Query: limit=20, offset=0
 */
router.get('/conversations', async (req, res, next) => {
  try {
    const limit = parseInt(req.query.limit, 10) || 20;
    const offset = parseInt(req.query.offset, 10) || 0;

    const result = await conversationService.listConversations(
      req.deviceUuid,
      Math.min(limit, 100),
      offset
    );

    res.json({
      code: 0,
      data: {
        list: result.list,
        total: result.total,
        limit,
        offset,
      },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/chat/conversation/:id/messages
 * 获取对话消息历史
 */
router.get('/conversation/:id/messages', async (req, res, next) => {
  try {
    const convId = parseInt(req.params.id, 10);
    if (isNaN(convId)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '对话 ID 格式无效',
      });
    }

    const messages = await conversationService.getHistory(convId);

    res.json({
      code: 0,
      data: { messages },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * DELETE /api/v1/chat/conversation/:id
 * 删除对话
 */
router.delete('/conversation/:id', async (req, res, next) => {
  try {
    const convId = parseInt(req.params.id, 10);
    if (isNaN(convId)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '对话 ID 格式无效',
      });
    }

    const deleted = await conversationService.deleteConversation(convId);

    if (!deleted) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '对话不存在',
      });
    }

    res.json({
      code: 0,
      data: null,
      message: '对话已删除',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;

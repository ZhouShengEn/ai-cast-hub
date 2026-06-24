/// 模型提供商与模型定义 — 统一管理本地直连和服务端模式的模型列表

/// 单个模型信息
class ModelInfo {
  final String id;
  final String name;
  const ModelInfo(this.id, this.name);
}

/// 提供商配置
class ProviderConfig {
  /// 提供商 key（用于 model ID 前缀，如 "openai:gpt-4o"）
  final String key;

  /// 显示名称
  final String displayName;

  /// API 端点（null = 仅服务端支持，不支持本地直连）
  final String? endpoint;

  /// 是否支持本地直连（OpenAI 兼容接口）
  final bool localSupported;

  /// 可用模型列表
  final List<ModelInfo> models;

  const ProviderConfig({
    required this.key,
    required this.displayName,
    this.endpoint,
    required this.localSupported,
    required this.models,
  });
}

/// 全局模型配置
class ModelConfig {
  ModelConfig._();

  /// 所有提供商
  static const List<ProviderConfig> providers = [
    ProviderConfig(
      key: 'openai',
      displayName: 'OpenAI',
      endpoint: 'https://api.openai.com/v1',
      localSupported: true,
      models: [
        ModelInfo('gpt-4o', 'GPT-4o'),
        ModelInfo('gpt-4o-mini', 'GPT-4o Mini'),
        ModelInfo('gpt-3.5-turbo', 'GPT-3.5 Turbo'),
      ],
    ),
    ProviderConfig(
      key: 'deepseek',
      displayName: 'DeepSeek',
      endpoint: 'https://api.deepseek.com/v1',
      localSupported: true,
      models: [
        ModelInfo('deepseek-chat', 'DeepSeek Chat'),
        ModelInfo('deepseek-reasoner', 'DeepSeek Reasoner'),
      ],
    ),
    ProviderConfig(
      key: 'qwen',
      displayName: '通义千问',
      endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      localSupported: true,
      models: [
        ModelInfo('qwen-turbo', 'Qwen Turbo'),
        ModelInfo('qwen-plus', 'Qwen Plus'),
        ModelInfo('qwen-max', 'Qwen Max'),
      ],
    ),
    ProviderConfig(
      key: 'glm',
      displayName: '智谱GLM',
      endpoint: 'https://open.bigmodel.cn/api/paas/v4',
      localSupported: true,
      models: [
        ModelInfo('glm-4', 'GLM-4'),
        ModelInfo('glm-4-flash', 'GLM-4 Flash'),
        ModelInfo('glm-4-air', 'GLM-4 Air'),
      ],
    ),
    ProviderConfig(
      key: 'claude',
      displayName: 'Anthropic Claude',
      endpoint: null,
      localSupported: false,
      models: [
        ModelInfo('claude-3-5-sonnet-20241022', 'Claude 3.5 Sonnet'),
        ModelInfo('claude-3-opus-20240229', 'Claude 3 Opus'),
      ],
    ),
    ProviderConfig(
      key: 'gemini',
      displayName: 'Google Gemini',
      endpoint: null,
      localSupported: false,
      models: [
        ModelInfo('gemini-1.5-pro', 'Gemini 1.5 Pro'),
        ModelInfo('gemini-1.5-flash', 'Gemini 1.5 Flash'),
      ],
    ),
  ];

  /// 获取支持本地直连的提供商
  static List<ProviderConfig> get localProviders =>
      providers.where((p) => p.localSupported).toList();

  /// 根据 provider key 获取配置
  static ProviderConfig? getProvider(String key) {
    for (final p in providers) {
      if (p.key == key) return p;
    }
    return null;
  }

  /// 构建 model ID: "openai:gpt-4o"
  static String buildModelId(String providerKey, String modelId) =>
      '$providerKey:$modelId';

  /// 解析 model ID → (providerKey, modelId)
  static ({String provider, String model}) parseModelId(String modelId) {
    final parts = modelId.split(':');
    if (parts.length > 1) {
      return (provider: parts[0], model: parts.sublist(1).join(':'));
    }
    return (provider: 'openai', model: modelId);
  }

  /// 根据 model ID 获取显示名称
  static String getModelDisplayName(String modelId) {
    final parsed = parseModelId(modelId);
    final provider = getProvider(parsed.provider);
    if (provider == null) return modelId;
    for (final m in provider.models) {
      if (m.id == parsed.model) return '${provider.displayName} ${m.name}';
    }
    return modelId;
  }
}

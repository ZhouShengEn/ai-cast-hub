import 'package:dio/dio.dart';

import '../utils/constants.dart';
import 'local_storage.dart';
import 'debug_service.dart';

/// Dio HTTP 客户端（单例模式）
///
/// 自动附加设备认证头，统一处理业务错误码。
class ApiClient {
  static ApiClient? _instance;
  late final Dio _dio;
  final LocalStorage _storage = LocalStorage.instance;

  ApiClient._() {
    _dio = Dio(BaseOptions(
      baseUrl: _storage.getServerUrl(),
      connectTimeout: AppConstants.httpConnectTimeout,
      receiveTimeout: AppConstants.httpReceiveTimeout,
      headers: {
        'Content-Type': 'application/json',
      },
    ));

    // 请求拦截器：自动附加认证头 + 网络日志
    final debugService = DebugService();
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final uuid = _storage.getDeviceUuid();
        final key = _storage.getTransferKey();
        if (uuid != null) {
          options.headers['X-Device-UUID'] = uuid;
        }
        if (key != null) {
          options.headers['X-Transfer-Key'] = key;
        }
        // 记录网络请求
        debugService.networkRequest(
          options.method,
          '${options.baseUrl}${options.path}',
          options.data,
          options.headers,
        );
        handler.next(options);
      },
      onResponse: (response, handler) {
        // 记录网络响应
        debugService.networkResponse(
          '${response.requestOptions.baseUrl}${response.requestOptions.path}',
          response.statusCode ?? 0,
          response.data,
        );

        // 检查业务错误码
        final data = response.data;
        if (data is Map<String, dynamic> && data.containsKey('code')) {
          final code = data['code'] as int;
          if (code != 0) {
            final message = data['message'] as String? ?? '未知错误';
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                response: response,
                message: message,
                type: DioExceptionType.badResponse,
              ),
              true,
            );
            return;
          }
        }
        handler.next(response);
      },
      onError: (error, handler) {
        // 记录网络错误
        debugService.networkError(
          '${error.requestOptions.baseUrl}${error.requestOptions.path}',
          error.message ?? '网络错误',
        );
        handler.next(error);
      },
    ));
  }

  /// 获取单例
  static ApiClient get instance {
    _instance ??= ApiClient._();
    return _instance!;
  }

  /// 获取原始 Dio 实例
  Dio get dio => _dio;

  /// 更新 baseUrl（切换服务器地址后调用）
  void updateBaseUrl(String url) {
    _dio.options.baseUrl = url;
  }

  /// GET 请求（自动解包 data 字段）
  Future<dynamic> get(String path, {Map<String, dynamic>? queryParameters}) async {
    final response = await _dio.get(path, queryParameters: queryParameters);
    final body = response.data as Map<String, dynamic>;
    return body['data'];
  }

  /// POST 请求（自动解包 data 字段）
  Future<dynamic> post(String path, {dynamic data}) async {
    final response = await _dio.post(path, data: data);
    final body = response.data as Map<String, dynamic>;
    return body['data'];
  }

  /// DELETE 请求（自动解包 data 字段）
  Future<dynamic> delete(String path) async {
    final response = await _dio.delete(path);
    final body = response.data as Map<String, dynamic>;
    return body['data'];
  }

  /// PUT 请求（自动解包 data 字段）
  Future<dynamic> put(String path, {dynamic data}) async {
    final response = await _dio.put(path, data: data);
    final body = response.data as Map<String, dynamic>;
    return body['data'];
  }
}

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'auth_session.dart';

class GraphQLService {
  static const String defaultApiUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://192.168.100.66:3000/graphql',
  );

  static String _currentUrl = defaultApiUrl;
  static String get apiUrl => _currentUrl;

  static final ValueNotifier<GraphQLClient> notifier =
      ValueNotifier<GraphQLClient>(getClient(apiUrl: defaultApiUrl));

  static void setApiUrl(String newUrl) {
    _currentUrl = newUrl.trim();
    notifier.value = getClient(apiUrl: _currentUrl);
  }

  static String resolveUrl(String url, {String? apiUrl}) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (!url.startsWith('/')) return url;

    final endpoint = Uri.parse(apiUrl ?? GraphQLService.apiUrl);
    final path = url.startsWith('/') ? url : '/$url';
    return Uri(
      scheme: endpoint.scheme,
      host: endpoint.host,
      port: endpoint.hasPort ? endpoint.port : null,
      path: path,
    ).toString();
  }

  static GraphQLClient getClient({String? apiUrl}) {
    final httpLink = HttpLink(apiUrl ?? GraphQLService.apiUrl);
    final authLink = AuthLink(
      getToken: () async {
        final token = AuthSession.token;
        if (token == null || token.isEmpty) return null;
        return 'Bearer $token';
      },
    );

    return GraphQLClient(
      link: authLink.concat(httpLink),
      cache: GraphQLCache(store: InMemoryStore()),
    );
  }

  static ValueNotifier<GraphQLClient> getClientNotifier({String? apiUrl}) {
    if (apiUrl != null && apiUrl != _currentUrl) {
      setApiUrl(apiUrl);
    }
    return notifier;
  }
}

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'auth_session.dart';

class GraphQLService {
  /// Passed at compile time: flutter run --dart-define=API_URL=http://HOST:3000/graphql
  static const String apiUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://127.0.0.1:3000/graphql',
  );

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
      cache: GraphQLCache(store: HiveStore()),
    );
  }

  static ValueNotifier<GraphQLClient> getClientNotifier({String? apiUrl}) {
    return ValueNotifier(getClient(apiUrl: apiUrl));
  }
}

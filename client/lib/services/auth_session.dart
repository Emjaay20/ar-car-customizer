class AuthSession {
  static String? token;
  static String? userId;
  static String? email;
  static String? fullName;

  static bool get isLoggedIn => token != null && userId != null;

  static void setFromLogin(Map<String, dynamic> payload) {
    token = payload['token'] as String;
    final user = payload['user'] as Map<String, dynamic>;
    userId = user['id'] as String;
    email = user['email'] as String;
    fullName = user['fullName'] as String;
  }

  static void clear() {
    token = null;
    userId = null;
    email = null;
    fullName = null;
  }
}

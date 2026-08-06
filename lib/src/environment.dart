/// Which PayCross backend to talk to.
enum PayCrossEnvironment {
  /// Test backend. Test cards work; real cards do not.
  sandbox,

  /// Live backend. Real money.
  production,
}

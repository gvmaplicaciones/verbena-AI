/// dd/mm/aaaa en horario local -- sin dependencia de intl para una sola fecha.
String formatShortDate(DateTime date) {
  final local = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year}';
}

/// The single money-rendering convention shared by the rider and driver apps.
///
/// The API keeps integer cents internally and rounds once, half-up, on the
/// final amount, then publishes **major currency units** on the JSON boundary
/// (dollars, not cents). Clients therefore render every fare at exactly two
/// decimals and never round it to whole dollars.
///
/// [currency] is the ISO-4217 code the API priced the fare in. It is rendered
/// as a prefix (`USD12.40`) and is **never invented or defaulted**: a null or
/// empty code renders the bare amount (`12.40`), matching the API contract
/// where a fare booked before the region pricing engine carries no currency.
String formatMoney(double value, {String? currency}) =>
    '${currency ?? ''}${value.toStringAsFixed(2)}';

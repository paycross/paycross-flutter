import '../demo/presets.dart';
import 'catalogue.dart';

String orderReference(DateTime placed) =>
    'ORDER-${placed.millisecondsSinceEpoch}';

String orderBody({required Product product, required String reference}) =>
    defaultBody(
      amount: product.price,
      currency: shopCurrency,
      reference: reference,
    );

String shopScenario(Product product) => 'shop:${product.slug}';

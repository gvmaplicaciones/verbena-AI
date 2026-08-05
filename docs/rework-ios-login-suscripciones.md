# Rework: inicio de sesión y suscripciones en iOS — diagnóstico y plan

> **Estado**: solo documento. No se ha modificado ningún archivo existente.
> Todos los cambios propuestos están apuntados aquí con código listo para
> aplicar cuando se decida.

## TL;DR

El problema no es un bug puntual de iOS: es que la **identidad de RevenueCat
solo se sincroniza con la sesión de Supabase en el arranque en frío**, y cada
cambio de sesión posterior (login, logout, borrar cuenta, modo admin) se
gestiona a mano en cada pantalla — o no se gestiona. Además, tras iniciar
sesión se llama a `restorePurchases()` automáticamente, que en iOS arrastra
**todo el recibo del Apple ID del dispositivo** a la cuenta recién logueada y
dispara eventos TRANSFER (la suscripción "rebota" entre cuentas, ya visto en
producción el 2026-08-05). En Android el restore de Play solo devuelve las
compras de la cuenta de Google actual, por eso allí "funciona perfecto" con el
mismo código.

El plan: centralizar la sincronización Supabase↔RevenueCat en un único
servicio nuevo, eliminar el restore automático (restore solo con el botón
"Restaurar compras"), arreglar los flujos de signOut/borrado que hoy dejan la
app en estado inconsistente, y simplificar Google Sign-In quitando el nonce
fijo de proceso (fuente probable del `bad_jwt` que se está depurando en iOS).

---

## 1. Por qué Android funciona y iOS no (con el mismo código)

`restorePurchases()` se comporta de forma distinta por plataforma:

- **Android (Play Billing)**: devuelve solo las compras activas de la cuenta
  de Google con la que está logueado el dispositivo, y desde Billing Library 8
  ni siquiera devuelve consumibles ya consumidos. Restaurar es "estrecho":
  rara vez mueve nada que no debiera.
- **iOS (StoreKit)**: sincroniza el **recibo completo del Apple ID** del
  dispositivo — todas las suscripciones y compras históricas hechas con ese
  Apple ID, da igual con qué cuenta de la app se compraran. Si el
  `appUserID` actual de RevenueCat no es el dueño original de ese recibo,
  RevenueCat aplica su *transfer behavior* (por defecto: "Transfer to new App
  User ID") → la suscripción **se mueve** a la cuenta actual y la anterior
  la pierde, generando el evento TRANSFER que ya hubo que parchear en el
  webhook (commits `f85cc10` y `9736b5c`).

Como `AccountGateScreen._reconcileAfterSignIn()` llama a
`Purchases.restorePurchases()` **automáticamente tras cada login**
(`account_gate_screen.dart:89-96`), en iOS cada inicio de sesión con otra
cuenta arrastra el recibo del dispositivo a esa cuenta. Es exactamente el
"rebote" documentado en el comentario de
`_confirmSignInIfActiveSubscription()` (`account_gate_screen.dart:112-118`).
Los dos diálogos de aviso que hay hoy (`Tienes una suscripción activa aquí`,
`Sesión recuperada` sin suscripción) son parches del síntoma, no de la causa.

---

## 2. Problemas encontrados (por orden de gravedad)

### P1 — Restore automático tras login (causa raíz del rebote de suscripciones)

`account_gate_screen.dart:86-110` (`_reconcileAfterSignIn`):

```dart
await Purchases.logIn(newUserId);
try {
  await Purchases.restorePurchases();   // ← esto, en iOS, transfiere el recibo
} catch (_) {}
```

RevenueCat desaconseja explícitamente llamar a restore de forma automática:
debe ser **siempre una acción explícita del usuario** (el botón "Restaurar
compras" del paywall, que ya existe y cumple el requisito de Apple). El
`reconcile()` server-side que se llama justo después ya consulta el estado
real del suscriptor en la API de RevenueCat — el restore automático no aporta
nada en el caso normal y rompe el caso de dos cuentas en un dispositivo.

**Cambio propuesto**: eliminar la llamada a `restorePurchases()` de
`_reconcileAfterSignIn()`. Quedaría solo `logIn` + `reconcile` + refresco de
créditos. (Con el servicio de la Fase A, ni siquiera hace falta el `logIn`
manual aquí.)

### P2 — La identidad de RevenueCat solo se fija en el arranque en frío

`main.dart:102-104`:

```dart
final purchasesConfig = PurchasesConfiguration(revenueCatApiKey)..appUserID = auth.currentUser!.id;
await Purchases.configure(purchasesConfig);
```

Después de esto, cada punto del código que cambia la sesión de Supabase tiene
que acordarse de llamar a `Purchases.logIn()`… y solo lo hace uno
(`account_gate_screen.dart:89`). Los demás no:

| Flujo | Archivo | Qué pasa con RevenueCat |
|---|---|---|
| Login desde AccountGate | `account_gate_screen.dart:89` | `logIn` manual (único caso cubierto) |
| Cerrar sesión (Perfil) | `profile_screen.dart:261` | **Nada** — sigue apuntando al usuario que se fue |
| Borrar mis datos | `account_repository.dart:15-24` | **Nada** — sigue apuntando al usuario borrado |
| Entrar/salir modo admin | `admin_repository.dart:56-85` | **Nada** |
| Restauración de sesión anónima en arranque | `main.dart:88-93` | Cubierto de rebote (configure va después) |

Consecuencia: compras, webhooks y `user_credits` pueden quedar atribuidos a un
`user_id` que ya no es el de la sesión activa. Este es el tipo de bug
"rebuscado" que hace que iOS "no lo gestione bien": no es una pieza rota, es
que no hay una única pieza responsable.

**Cambio propuesto**: servicio central que escucha `onAuthStateChange` y
mantiene RevenueCat sincronizado siempre (ver Fase A). Los `logIn` manuales
dispersos se eliminan.

### P3 — Cerrar sesión deja la app sin sesión de Supabase

`profile_screen.dart:259-263`:

```dart
await ref.read(authRepositoryProvider).signOut();
if (!mounted) return;
context.go(AppRoutes.onboarding);
```

Tras `signOut()` **nadie vuelve a crear la sesión anónima** (a diferencia de
`deleteMyDataAndRestart`, que sí lo hace). La app queda sin sesión: cualquier
llamada a Supabase (créditos, plantillas, generación) falla hasta el
siguiente arranque en frío, cuando `main.dart:91-93` detecta
`currentSession == null` y hace `signInAnonymously()`. Además no se invalidan
los providers cacheados (`myCreditsProvider`, `myGenerationsProvider`…), que
siguen sirviendo datos de la cuenta cerrada.

**Cambio propuesto**: método nuevo `signOutAndStartFresh()` en
`AuthRepository` (código en Fase A.3) que hace signOut → signInAnonymously, y
que el caller invalide los mismos providers que ya invalida
`_confirmDeleteData` (`profile_screen.dart:310-313`).

### P4 — "Borrar mis datos" deja RevenueCat apuntando al usuario borrado

`account_repository.dart:15-24` crea la nueva sesión anónima pero RevenueCat
sigue configurado con el uid borrado. Si el usuario compra después, el
webhook concede créditos a una fila de `user_credits` que ya no existe. Se
resuelve solo con el servicio de la Fase A (el listener ve el uid nuevo y
hace `logIn`), sin tocar `AccountRepository`.

### P5 — Google Sign-In no estándar: nonce fijo de proceso (probable origen del `bad_jwt` en iOS)

Situación actual:

- `main.dart:70-73` pasa un `nonce` **fijo para toda la vida del proceso** a
  `GoogleSignIn.instance.initialize()` (hack asumido en el comentario de
  `auth_repository.dart:47-54`: como initialize solo puede llamarse una vez,
  no se puede regenerar por intento).
- `auth_repository.dart:13-45` tiene un TODO de depuración activo por
  `AuthException(bad_jwt)` / "missing sub claim" en
  `linkIdentityWithIdToken` con Google **en el iPhone de prueba**.

Dos hechos relevantes para iOS:

1. El flujo nativo estándar de Supabase para Google en Flutter **no usa nonce
   en absoluto** (la guía oficial de Supabase con `google_sign_in` llama a
   `signInWithIdToken(provider: google, idToken: idToken)` sin nonce). El
   nonce aquí es opcional; con Apple sí es obligatorio y ya está bien hecho
   (por intento, en `_appleTokens`).
2. En iOS el SDK nativo de Google emite el idToken con **audiencia = client
   ID de iOS** (el `GIDClientID` del Info.plist,
   `816132193114-5fvfnnjro36ur2eec00kv8ipe5h24gvq...`); `serverClientId` no
   cambia la audiencia del idToken en iOS como sí hace en Android. Supabase
   rechaza el token si esa audiencia no está en la lista de client IDs
   autorizados del proveedor Google. Como Android funciona, el client ID web
   seguro que está registrado — **hay que comprobar que el de iOS también**
   (Dashboard Supabase → Authentication → Providers → Google → "Authorized
   Client IDs": deben estar el web Y el de iOS, separados por coma).

**Cambio propuesto**: quitar el nonce de Google por completo (initialize sin
`nonce`, y `linkGoogle`/`signInWithGoogle` sin parámetro `nonce`), verificar
la lista de client IDs en el dashboard, y entonces retirar el TODO de
depuración (`_debugLogIdTokenPayload` y su import de Sentry). Se elimina toda
la clase de fallos por nonce (fijo, desincronizado o no incrustado según
plataforma) de una vez. Apple no se toca: su flujo actual es el estándar.

### P6 — Sin listener de `CustomerInfo`: la UI depende de invalidaciones manuales

No hay ningún `Purchases.addCustomerInfoUpdateListener` en el proyecto. Todo
refresco de créditos tras un evento de compra depende de que el sitio
concreto llame a `reconcile()` + `ref.invalidate(myCreditsProvider)`. Dos
huecos visibles:

- Pago pendiente (`paymentPendingError` o compra sin entitlement local,
  `paywall_screen.dart:114-123`): se enseña "te avisaremos en cuanto se
  confirme"… pero no hay nada escuchando la confirmación. El usuario se
  queda sin acceso hasta que algo más dispare un reconcile.
- Renovación/expiración mientras la app está abierta: el estado local no se
  entera hasta reabrir el paywall o el perfil.

**Cambio propuesto**: el servicio de la Fase A registra el listener y, cuando
el entitlement activo cambia respecto a lo último visto, dispara
`reconcile()` + invalidación de créditos. Es el mecanismo estándar del SDK
para esto.

### P7 — Menor: modo admin no toca RevenueCat

`admin_repository.dart:56-85` cambia a la sesión real del admin y vuelve, sin
tocar RevenueCat. Riesgo bajo (uso interno), y el servicio de la Fase A lo
cubre automáticamente sin cambiar `AdminRepository`. Solo hay que tener en
cuenta que el uid del admin nunca tendrá fila en `user_credits` — el listener
hace `logIn` igualmente y no pasa nada (no se compra nada en modo admin).

---

## 3. Plan de rework (estándar, por fases)

### Fase A — Sincronización central Supabase ↔ RevenueCat

#### A.1 Archivo NUEVO: `lib/services/purchases_auth_sync.dart`

Único responsable de que `Purchases.appUserID` == uid de Supabase, siempre.
Código completo propuesto:

```dart
import 'dart:async';
import 'dart:developer' as developer;

import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/credits.dart';

/// Mantiene la identidad de RevenueCat sincronizada con la sesión de
/// Supabase durante toda la vida del proceso. Sustituye a los
/// Purchases.logIn() manuales dispersos por pantallas: cualquier cambio de
/// sesión (login real, signOut+anónima nueva, borrar cuenta, modo admin)
/// pasa por aquí sin que el caller tenga que acordarse de nada.
///
/// NUNCA llama a restorePurchases(): en iOS restaurar arrastra el recibo
/// completo del Apple ID del dispositivo al appUserID actual y dispara
/// TRANSFER (rebote de suscripción entre cuentas, visto en producción el
/// 2026-08-05). Restaurar es siempre una acción explícita del usuario desde
/// el botón "Restaurar compras" del paywall.
class PurchasesAuthSync {
  PurchasesAuthSync._();

  static StreamSubscription<AuthState>? _authSub;
  static String? _lastSyncedUserId;
  static bool _lastHadEntitlement = false;

  /// Llamar una vez desde main(), después de Purchases.configure() y antes
  /// de runApp(). [onEntitlementChanged] permite al arranque enganchar el
  /// refresco de créditos (reconcile + invalidate) sin que este servicio
  /// dependa de Riverpod.
  static void start(GoTrueClient auth, {Future<void> Function()? onEntitlementChanged}) {
    _lastSyncedUserId = auth.currentUser?.id;

    _authSub?.cancel();
    _authSub = auth.onAuthStateChange.listen((data) {
      final userId = data.session?.user.id;
      // Sesión cerrada sin sustituta todavía (transitorio dentro de
      // signOutAndStartFresh o del cambio a modo admin): no hay identidad
      // nueva que sincronizar aún; el evento del signIn siguiente ya traerá
      // el uid definitivo.
      if (userId == null || userId == _lastSyncedUserId) return;
      _lastSyncedUserId = userId;
      unawaited(_logInSafely(userId));
    });

    // Refresco reactivo del estado de compra (renovaciones, pagos pendientes
    // que se confirman, cambios hechos desde otro dispositivo...): el SDK
    // emite CustomerInfo cada vez que cambia; solo interesa cuando el
    // entitlement activo cambia de verdad.
    Purchases.addCustomerInfoUpdateListener((customerInfo) {
      final hasEntitlement =
          customerInfo.entitlements.active.containsKey(RevenueCatEntitlements.pro);
      if (hasEntitlement == _lastHadEntitlement) return;
      _lastHadEntitlement = hasEntitlement;
      if (onEntitlementChanged != null) unawaited(onEntitlementChanged());
    });
  }

  static Future<void> _logInSafely(String userId) async {
    try {
      await Purchases.logIn(userId);
    } catch (e, st) {
      developer.log('Purchases.logIn failed for $userId',
          name: 'PurchasesAuthSync', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'purchasesAuthSync'})));
    }
  }
}
```

Cableado en `main.dart` (cambio a apuntar, no aplicado): justo después de
`await Purchases.configure(purchasesConfig);` añadir

```dart
PurchasesAuthSync.start(auth, onEntitlementChanged: () async {
  // reconcile server-side + invalidación de myCreditsProvider; se resuelve
  // con el ProviderContainer raíz (ver nota abajo).
});
```

Nota de implementación: para poder invalidar `myCreditsProvider` desde fuera
del árbol de widgets, crear el `ProviderScope` de `main.dart` con un
`ProviderContainer` explícito (patrón estándar de Riverpod:
`UncontrolledProviderScope(container: container, ...)`) y usar
`container.read(purchasesRepositoryProvider).reconcile()` +
`container.invalidate(myCreditsProvider)` en el callback.

#### A.2 `AccountGateScreen._reconcileAfterSignIn` — simplificar

Cambio a apuntar (no aplicado): quitar `Purchases.logIn(newUserId)` (lo hace
el servicio) y **quitar `Purchases.restorePurchases()`** (P1). Queda:

```dart
Future<bool> _reconcileAfterSignIn() async {
  try {
    await ref.read(purchasesRepositoryProvider).reconcile();
  } catch (_) {}
  ref.invalidate(myCreditsProvider);
  try {
    final credits = await ref.read(myCreditsProvider.future);
    return credits.hasActiveAccess;
  } catch (_) {
    return true;
  }
}
```

Con esto, iniciar sesión con la cuenta B en un dispositivo cuya suscripción
vive en la cuenta A **ya no roba la suscripción**: `reconcile()` consulta el
estado real de B en RevenueCat y punto. Si el usuario de verdad quiere
traerse la compra del dispositivo a B, pulsa "Restaurar compras" — acción
consciente, comportamiento estándar. Los dos diálogos de aviso
(`_confirmSignInIfActiveSubscription`, `_showNoActiveSubscriptionNotice`)
pueden mantenerse como red de seguridad informativa; dejan de ser el único
freno.

#### A.3 Método NUEVO en `AuthRepository`: `signOutAndStartFresh()`

```dart
/// Cierra la sesión real y arranca inmediatamente una sesión anónima nueva,
/// dejando la app en el mismo estado que un usuario recién instalado (mismo
/// patrón que AccountRepository.deleteMyDataAndRestart). RevenueCat se
/// re-sincroniza solo vía PurchasesAuthSync al emitirse el signIn anónimo.
Future<void> signOutAndStartFresh() async {
  await _client.auth.signOut();
  await _client.auth.signInAnonymously();
}
```

Y en `profile_screen.dart` (`_confirmSignOut`, cambio a apuntar): llamar a
`signOutAndStartFresh()` en vez de `signOut()`, e invalidar los mismos
providers que ya invalida `_confirmDeleteData`
(`myGenerationsProvider`, `persistedPhotosProvider`, `myCreditsProvider`,
`garmentsProvider`) antes de `context.go(AppRoutes.onboarding)`.

#### A.4 `AccountRepository.deleteMyDataAndRestart` — sin cambios

Con el servicio A.1 escuchando, la nueva sesión anónima que ya crea este
método re-apunta RevenueCat automáticamente. No hay que tocarlo.

### Fase B — Google Sign-In estándar (P5)

Cambios a apuntar (no aplicados):

1. `main.dart`: `GoogleSignIn.instance.initialize(serverClientId: Env.googleWebClientId)`
   — sin `nonce`.
2. `auth_repository.dart`: eliminar `googleSignInRawNonce` /
   `googleSignInHashedNonce`; `linkGoogle()` y `signInWithGoogle()` llaman a
   `linkIdentityWithIdToken` / `signInWithIdToken` **sin** parámetro `nonce`.
   Apple se queda exactamente como está.
3. Retirar el TODO de depuración `_debugLogIdTokenPayload` (y el import de
   `sentry_flutter` si queda sin uso en ese archivo).
4. **Configuración (sin código)** — verificar en el dashboard de Supabase
   (Authentication → Providers → Google → Authorized Client IDs) que están
   los DOS client IDs: el web (`Env.googleWebClientId`, que ya funciona
   porque Android entra) y el de iOS
   (`816132193114-5fvfnnjro36ur2eec00kv8ipe5h24gvq.apps.googleusercontent.com`,
   el `GIDClientID` del Info.plist). En iOS la audiencia del idToken es el
   client ID de iOS, no el web — si falta de la lista, el login con Google
   falla SOLO en iOS, que encaja con lo observado.
5. Con Apple, mismo checklist una vez: en Supabase (Providers → Apple →
   Authorized Client IDs) debe estar el **bundle ID de la app iOS** (flujo
   nativo; el Services ID solo aplica al flujo web).

### Fase C — Configuración en el dashboard de RevenueCat (sin código)

1. **Transfer behavior** (Project Settings → General → Restore behavior):
   confirmar el valor actual. Recomendación: dejar "Transfer to new App User
   ID" (el default) — una vez eliminado el restore automático (A.2), solo se
   transfiere cuando el usuario pulsa "Restaurar compras" a sabiendas. Si se
   quiere ser más conservador, "Transfer if there are no active
   subscriptions" evita robos incluso con restore manual, a costa de que un
   restore legítimo con dos cuentas requiera soporte.
2. Verificar que los productos de iOS (App Store Connect) están adjuntos al
   entitlement `verbenAI Pro` igual que los de Play — el reconcile ya loguea
   un error explícito si detecta la desconexión
   (`_shared/revenuecat.ts:450-461`), revisar Sentry/logs de la Edge
   Function por si ya está saltando en iOS.

### Qué NO cambiar (funciona y es correcto)

- Toda la capa server-side: `revenuecat-webhook`, `revenuecat-reconcile`,
  `_shared/revenuecat.ts` (incluye ya los fixes de TRANSFER, UNCANCELLATION,
  dedupe de packs). El rework es 100% cliente + configuración.
- El flujo de Apple Sign-In (nonce por intento — estándar).
- El paywall (`requireEntitlement`, precios desde `offeringsProvider`
  autoDispose, botón de restore manual). Solo se beneficia del listener de
  A.1 para el caso "pago pendiente".
- El pinning exacto de `purchases_flutter: 10.4.2` y el pendiente conocido
  del pack extra no restaurable (CLAUDE.md) — sin relación con esto.

---

## 4. Orden de implementación sugerido

| Paso | Cambio | Riesgo | Depende de |
|---|---|---|---|
| 1 | Checklists de configuración (B.4, B.5, C.1, C.2) | Nulo (solo dashboards) | — |
| 2 | Fase B (Google sin nonce) | Bajo | 1 |
| 3 | A.1 servicio + cableado en main | Medio | — |
| 4 | A.2 quitar restore automático | Bajo | 3 |
| 5 | A.3 signOutAndStartFresh | Bajo | 3 |

Tras cada paso con código Dart: `flutter pub get` + `flutter analyze`
(convención del proyecto — en el entorno donde se escribió este documento no
hay SDK de Flutter, así que nada de lo anterior está compilado/verificado).

## 5. Matriz de pruebas (sandbox, dispositivo iOS real)

1. **Login Google en iOS** (tras paso 2): vincular cuenta nueva y también
   iniciar sesión existente. Verificar que desaparece el `bad_jwt`.
2. **Compra semanal → cerrar sesión → sesión anónima nueva**: la anónima no
   debe tener acceso; el uid de RevenueCat debe ser el anónimo nuevo
   (visible en los logs del SDK con `LogLevel.info`).
3. **Volver a iniciar sesión con la cuenta compradora**: acceso recuperado
   solo con `reconcile()`, sin pulsar restore, sin evento TRANSFER.
4. **Dos cuentas en el mismo dispositivo** (el caso del 2026-08-05): comprar
   con A, entrar con B → B NO recibe la suscripción y A la conserva.
   Pulsar "Restaurar compras" estando en B → ahora sí se transfiere
   (comportamiento elegido en C.1) y el webhook TRANSFER expira A.
5. **Reinstalar la app con suscripción activa**: iniciar sesión → acceso
   recuperado vía reconcile. Pulsar restore solo si la cuenta era anónima
   pura (caso del pendiente conocido de CLAUDE.md).
6. **Borrar mis datos → comprar de nuevo**: la compra debe conceder créditos
   al uid anónimo nuevo (verifica P4).
7. **Pago pendiente** (tarjeta de aprobación diferida en sandbox): al
   confirmarse, el listener de A.1 debe refrescar créditos sin reabrir el
   paywall.

---

## 6. ¿Y Android? — impacto del rework en la plataforma que "funciona"

Android funciona hoy en parte por suerte: varios de los problemas de arriba
son multiplataforma y existen también allí, solo que no duelen (todavía) o
son menos probables. **No hace falta ningún cambio exclusivo de Android**: al
ser un único codebase, aplicar las fases A y B lo arregla en las dos
plataformas a la vez. Estado real de cada problema en Android:

| Problema | ¿Afecta a Android hoy? | Detalle |
|---|---|---|
| P1 rebote por restore automático | **Sí, menos probable** | El restore de Play también transfiere la suscripción si se compró bajo otra cuenta de la app con la misma cuenta de Google del dispositivo. La diferencia con iOS es de alcance (Play no arrastra todo el historial del Apple ID), no de inmunidad. A.2 lo elimina en ambas. |
| P2 identidad RevenueCat solo en arranque | **Sí, idéntico** | Mismo código, mismos huecos. A.1 lo cubre en ambas. |
| P3 signOut deja la app sin sesión | **Sí, idéntico** | Bug real hoy en Android: tras cerrar sesión, todo falla hasta reiniciar la app. Si no se ha reportado es porque casi nadie usa ese botón aún. A.3 lo arregla. |
| P4 borrar datos deja RevenueCat en el uid borrado | **Sí, idéntico** | Una compra posterior al borrado concedería créditos a una cuenta inexistente, también en Android. A.1 lo cubre. |
| P5 Google Sign-In con nonce fijo | No (funciona) | Funciona de casualidad porque en Android el nonce sí acaba incrustado y la audiencia es el client ID web ya autorizado. Quitar el nonce (Fase B) es el flujo estándar y sigue funcionando — solo repetir la prueba de login en Android tras el cambio. |
| P6 sin listener de CustomerInfo | **Sí, y MÁS que en iOS** | Los pagos pendientes (métodos de pago lentos) son un clásico de Google Play, raros en App Store. Hoy "te avisaremos en cuanto se confirme" no tiene nada escuchando detrás. El listener de A.1 lo cubre. |
| P7 modo admin sin re-sync | Sí, menor | Igual en ambas; cubierto por A.1 sin tocar AdminRepository. |

Implicación para las pruebas: la matriz de la sección 5 debe pasarse
**también en un dispositivo Android** tras el rework — en especial los casos
2, 3, 6 (sesiones) y 7 (pago pendiente, que en Android es el caso común de
verdad), y un login con Google normal tras quitar el nonce.

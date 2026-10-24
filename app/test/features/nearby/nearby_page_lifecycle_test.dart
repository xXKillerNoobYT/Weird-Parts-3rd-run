import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/daos/settings_dao.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_page.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

class _GatedSettings extends SettingsDao {
  _GatedSettings(super.db);

  final queries = <Completer<String>>[];
  String? _releasedName;

  @override
  Future<String> deviceDisplayName() {
    final query = Completer<String>();
    queries.add(query);
    final name = _releasedName;
    if (name != null) query.complete(name);
    return query.future;
  }

  void release([String name = 'Shop Mac']) {
    _releasedName = name;
    for (final query in queries) {
      if (!query.isCompleted) query.complete(name);
    }
  }
}

class _Database extends AppDatabase {
  _Database() : super.forTesting(NativeDatabase.memory());

  late final _settings = _GatedSettings(this);

  @override
  _GatedSettings get settingsDao => _settings;
}

class _Discovery implements NearbyDiscovery {
  final updates = StreamController<List<NearbyPeer>>.broadcast();
  bool advertising = false;

  @override
  Stream<List<NearbyPeer>> get peers => updates.stream;

  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    advertising = true;
  }

  @override
  Future<void> stop() async {
    advertising = false;
  }

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {}
}

class _HttpServer extends Stream<HttpRequest> implements HttpServer {
  final requests = StreamController<HttpRequest>();
  bool closed = false;

  bool get listening => !closed && requests.hasListener;

  @override
  InternetAddress get address => InternetAddress('192.168.1.2');

  @override
  int get port => 62000;

  @override
  StreamSubscription<HttpRequest> listen(
    void Function(HttpRequest)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => requests.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Future<HttpServer> close({bool force = false}) async {
    closed = true;
    await requests.close();
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Network extends NearbyWifiNetwork {
  _Network()
    : super(name: 'test', index: 1, address: '192.168.1.2', prefixLength: 24);

  _HttpServer? server;

  @override
  Future<HttpServer> listen() async => server = _HttpServer();

  @override
  Future<void> close() async {}
}

class _Owner {
  _Owner({required String deviceId, required String deviceName}) {
    controller = NearbyController(
      deviceId: deviceId,
      deviceName: deviceName,
      discovery: discovery,
      readNetwork: () async => network,
      collectPayload: () async => throw StateError('Startup must not export'),
      applyPayload: (_) async => throw StateError('Startup must not import'),
    );
  }

  final network = _Network();
  final discovery = _Discovery();
  late final NearbyController controller;
}

class _Fixture {
  _Fixture() {
    addTearDown(db.close);
  }

  final db = _Database();
  final owners = <_Owner>[];
  late final page = NearbyPage(
    createController:
        ({
          required String deviceId,
          required String deviceName,
          required AppDatabase db,
          required Future<({BackupPayload payload, NearbyOffer offer})>
          Function()
          collectPayload,
          required NearbyApplyPayload applyPayload,
        }) {
          final owner = _Owner(deviceId: deviceId, deviceName: deviceName);
          owners.add(owner);
          return owner.controller;
        },
  );

  Widget get widget => wrap(page);

  Widget wrap(NearbyPage nearbyPage, {AppDatabase? database}) {
    final currentDb = database ?? db;
    return AppScope(
      db: currentDb,
      pin: PinService(currentDb.settingsDao),
      deviceId: 'mac',
      wipeLocalData: () async {},
      restoreFromBackup: (_, _) async {},
      child: MaterialApp(home: nearbyPage),
    );
  }

  ({int servers, int peerListeners, int advertisements}) get resources => (
    servers: owners.where((o) => o.network.server?.listening ?? false).length,
    peerListeners: owners.where((o) => o.discovery.updates.hasListener).length,
    advertisements: owners.where((o) => o.discovery.advertising).length,
  );

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    db.settingsDao.release();
    await tester.pumpAndSettle();
    for (final owner in owners) {
      unawaited(owner.controller.dispose());
    }
    await tester.pumpAndSettle();
    expect(resources, (servers: 0, peerListeners: 0, advertisements: 0));
    for (final owner in owners) {
      unawaited(owner.discovery.updates.close());
    }
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'mounted startup discovers peers and unmount releases listeners',
    (tester) async {
      final fixture = _Fixture();
      try {
        await tester.pumpWidget(fixture.widget);
        expect(find.text('Opening Nearby…'), findsOneWidget);
        fixture.db.settingsDao.release();
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Visible on this Wi‑Fi as Shop Mac.'),
          findsOneWidget,
        );
        expect(fixture.resources, (
          servers: 1,
          peerListeners: 1,
          advertisements: 1,
        ));

        fixture.owners.single.discovery.updates.add(const [
          NearbyPeer(
            deviceId: 'peer',
            name: 'Peer shop',
            host: '192.168.1.3',
            port: 62001,
          ),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('Peer shop'), findsOneWidget);
        expect(find.text('Pair'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(fixture.resources, (
          servers: 0,
          peerListeners: 0,
          advertisements: 0,
        ));
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('unmount during device-name lookup leaves Nearby off', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await tester.pumpWidget(fixture.widget);
      expect(find.text('Opening Nearby…'), findsOneWidget);
      expect(fixture.db.settingsDao.queries, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      fixture.db.settingsDao.release();
      await tester.pumpAndSettle();

      expect(find.byType(NearbyPage), findsNothing);
      expect(fixture.resources, (
        servers: 0,
        peerListeners: 0,
        advertisements: 0,
      ));
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('scope notifications during startup retain one Nearby owner', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await tester.pumpWidget(fixture.widget);
      expect(find.text('Opening Nearby…'), findsOneWidget);
      await tester.pumpWidget(fixture.widget);
      await tester.pumpWidget(fixture.widget);
      fixture.db.settingsDao.release();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Visible on this Wi‑Fi as Shop Mac.'),
        findsOneWidget,
      );
      expect(fixture.resources, (
        servers: 1,
        peerListeners: 1,
        advertisements: 1,
      ));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(fixture.resources, (
        servers: 0,
        peerListeners: 0,
        advertisements: 0,
      ));
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('replacement scope wins over an older pending startup', (
    tester,
  ) async {
    final fixture = _Fixture();
    final replacementDb = _Database();
    addTearDown(replacementDb.close);
    try {
      await tester.pumpWidget(fixture.widget);
      expect(find.text('Opening Nearby…'), findsOneWidget);
      expect(fixture.db.settingsDao.queries, isNotEmpty);

      await tester.pumpWidget(
        fixture.wrap(fixture.page, database: replacementDb),
      );
      replacementDb.settingsDao.release('Replacement shop');
      await tester.pumpAndSettle();
      fixture.db.settingsDao.release('Old shop');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Visible on this Wi‑Fi as Replacement shop.'),
        findsOneWidget,
      );
      expect(fixture.resources, (
        servers: 1,
        peerListeners: 1,
        advertisements: 1,
      ));
      expect(
        fixture.owners.where(
          (owner) =>
              owner.controller.deviceName == 'Old shop' &&
              owner.network.server != null,
        ),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(fixture.resources, (
        servers: 0,
        peerListeners: 0,
        advertisements: 0,
      ));
    } finally {
      replacementDb.settingsDao.release('Replacement shop');
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'caller owns controller startup and lifetime across page mounts',
    (tester) async {
      final fixture = _Fixture();
      final owner = _Owner(deviceId: 'caller', deviceName: 'Caller shop');
      fixture.owners.add(owner);
      final page = NearbyPage(controller: owner.controller);
      try {
        await tester.pumpWidget(fixture.wrap(page));
        await tester.pumpAndSettle();
        expect(owner.controller.state.phase, NearbyPhase.idle);
        expect(fixture.resources, (
          servers: 0,
          peerListeners: 0,
          advertisements: 0,
        ));

        unawaited(owner.controller.start());
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Visible on this Wi‑Fi as Caller shop.'),
          findsOneWidget,
        );
        owner.discovery.updates.add(const [
          NearbyPeer(
            deviceId: 'peer',
            name: 'First peer',
            host: '192.168.1.3',
            port: 62001,
          ),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('First peer'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(fixture.resources, (
          servers: 1,
          peerListeners: 1,
          advertisements: 1,
        ));

        await tester.pumpWidget(fixture.wrap(page));
        await tester.pumpAndSettle();
        expect(find.text('First peer'), findsOneWidget);
        owner.discovery.updates.add(const [
          NearbyPeer(
            deviceId: 'peer',
            name: 'Later peer',
            host: '192.168.1.3',
            port: 62001,
          ),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('Later peer'), findsOneWidget);
        expect(find.text('First peer'), findsNothing);
        expect(fixture.resources, (
          servers: 1,
          peerListeners: 1,
          advertisements: 1,
        ));

        unawaited(owner.controller.dispose());
        await tester.pumpAndSettle();
        expect(fixture.resources, (
          servers: 0,
          peerListeners: 0,
          advertisements: 0,
        ));
      } finally {
        await fixture.dispose(tester);
      }
    },
  );
}

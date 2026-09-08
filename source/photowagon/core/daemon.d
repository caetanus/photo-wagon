/// The core: wiring and lifecycle of every service, and the two ways to run
/// it — on a thread of its own behind the UI, or on the main thread headless.
/// Everything else lives in a package with one responsibility; this file only
/// decides the order things start and stop in.
module photowagon.core.daemon;

import core.thread : Thread;
import std.conv : to;
import std.file : mkdirRecurse, write, remove, exists;
import std.path : buildPath;

import vibe.core.core : runTask, runEventLoop, exitEventLoop;
import vibe.core.log : logInfo, logWarn, logError;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.api.album_api : registerAlbumApi;
import photowagon.core.api.daemon_api : registerDaemonApi;
import photowagon.core.api.import_api : registerImportApi;
import photowagon.core.api.library_api : registerLibraryApi;
import photowagon.core.api.media_api : registerMediaApi;
import photowagon.core.api.p2p_api : registerP2pApi;
import photowagon.core.api.pairing_api : registerPairingApi, ServerControl;
import photowagon.core.config : Config;
import photowagon.core.db.schema : migrate;
import photowagon.core.db.sqlite : Database;
import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.handler : RequestHandler;
import photowagon.core.ipc.link : InProcessLink;
import photowagon.core.ipc.protocol : Registry;
import photowagon.core.ipc.server : IpcServer;
import photowagon.core.library.albums : AlbumRepo;
import photowagon.core.library.dates : DateTree;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.library.roots : RootRepo;
import photowagon.core.p2p.identity : loadOrCreateIdentity;
import photowagon.core.p2p.node : Node;
import photowagon.core.p2p.peers : PeerRepo;
import photowagon.core.p2p.sharing : Sharing;
import photowagon.core.pairing : loadOrCreateToken;
import photowagon.core.store.store : ContentStore;

enum coreVersion = "0.4.0";

final class Daemon : ServerControl
{
	private Config cfg;
	private InProcessLink link; // null when headless
	private Database db;
	private IpcServer ipc;
	private Registry registry;
	private Events events;
	private string token;
	private ushort ipcPortInUse;
	private RequestHandler inproc;
	private FiberGroup own;
	private Indexer indexer;
	private Node node;
	private Sharing sharing;
	private bool stopped;

	this(Config cfg, InProcessLink link = null)
	{
		this.cfg = cfg;
		this.link = link;
		own = new FiberGroup((Exception e) nothrow {
			try
				logError("core: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	/// Must run on a fiber of the event loop that will host the services.
	void start()
	{
		mkdirRecurse(cfg.dataDir);
		db = new Database(cfg.dbPath);
		migrate(db);
		auto store = new ContentStore(cfg.storeDir);
		events = new Events;
		token = loadOrCreateToken(buildPath(cfg.dataDir, "pair.token"));
		auto roots = new RootRepo(db);
		auto photos = new PhotoRepo(db, store);
		auto dates = new DateTree(db);
		auto albums = new AlbumRepo(db);
		indexer = new Indexer(cfg, photos, events);

		if (cfg.p2p)
		{
			try
			{
				node = new Node(loadOrCreateIdentity(cfg.identityPath), cfg, events, new PeerRepo(db));
				node.start();
				sharing = new Sharing(node, store, photos, albums, events);
			}
			catch (Exception e)
			{
				logWarn("p2p disabled: %s", e.msg);
				node = null;
				sharing = null;
			}
		}

		registry = new Registry;
		registerDaemonApi(registry, cfg, node, &requestStop);
		registerPairingApi(registry, this);
		registerLibraryApi(registry, roots, photos, dates, indexer, events);
		registerMediaApi(registry, photos, store);
		registerImportApi(registry, cfg, roots, photos, indexer);
		registerAlbumApi(registry, albums, photos, sharing);
		registerP2pApi(registry, node, sharing);

		if (link !is null)
		{
			inproc = new RequestHandler(registry, &link.deliver);
			events.attach(&link.deliver);
			own.spawn(&pumpLink);
			logInfo("core %s: serving the UI in-process, data in %s", coreVersion, cfg.dataDir);
		}
		if (cfg.serve)
			startServing(cfg.ipcAddress);

		// pick up changes since last run
		foreach (root; roots.list())
			indexer.start(root.id, root.path);
	}

	// ---- ServerControl: the loopback/LAN listener, on demand ------------------------

	ushort startServing(string address)
	{
		if (ipc !is null)
			return ipcPortInUse;
		mkdirRecurse(cfg.runtimeDir);
		ipc = new IpcServer(registry, events, token);
		ipcPortInUse = ipc.listen(address, cfg.ipcPort);
		write(cfg.portFile, ipcPortInUse.to!string ~ "\n");
		logInfo("core %s: ipc on %s:%s (port file %s), data in %s", coreVersion, address, ipcPortInUse, cfg.portFile, cfg.dataDir);
		return ipcPortInUse;
	}

	void stopServing()
	{
		if (ipc is null)
			return;
		ipc.close();
		ipc = null;
		try
			if (cfg.portFile.exists)
				remove(cfg.portFile);
		catch (Exception)
		{
		}
	}

	bool serving()
	{
		return ipc !is null;
	}

	ushort servingPort()
	{
		return ipcPortInUse;
	}

	string pairingToken()
	{
		return token;
	}

	/// Moves request lines from the UI to the handler, for as long as the core runs.
	private void pumpLink()
	{
		int seen = link.emitCount;
		while (true)
		{
			foreach (line; link.takeInbox())
				inproc.handle(line);
			seen = link.waitForInput(seen);
		}
	}

	private void requestStop()
	{
		exitEventLoop();
	}

	void stop() nothrow
	{
		if (stopped)
			return;
		stopped = true;
		try
			logInfo("core: shutting down");
		catch (Exception)
		{
		}
		own.stopAll();
		if (inproc)
			inproc.close();
		if (ipc)
			ipc.close();
		if (indexer)
			indexer.close();
		if (sharing)
			sharing.close();
		if (node)
			node.close();
		if (db)
			db.close();
		try
			if (cfg.portFile.exists)
				remove(cfg.portFile);
		catch (Exception)
		{
		}
	}
}

/// Runs a `Daemon` to completion on the calling thread. Returns the exit code.
int runCore(Config cfg, InProcessLink link = null)
{
	auto daemon = new Daemon(cfg, link);
	int rc;
	runTask(() nothrow {
		try
			daemon.start();
		catch (Exception e)
		{
			try
				logError("core: startup failed: %s", e.msg);
			catch (Exception)
			{
			}
			rc = 1;
			try
				exitEventLoop();
			catch (Exception)
			{
			}
		}
	});
	runEventLoop();
	daemon.stop();
	return rc;
}

/// The core on a thread of its own, with its own vibe event loop, behind a UI
/// that owns the main thread. `stop()` asks it to finish and joins it.
final class CoreThread
{
	private Thread thread;
	private InProcessLink link;
	private Config cfg;
	private int rc;

	this(Config cfg, InProcessLink link)
	{
		this.cfg = cfg;
		this.link = link;
	}

	void start()
	{
		thread = new Thread(() { rc = runCore(cfg, link); });
		thread.name = "photowagon-core";
		thread.start();
	}

	/// Asks the core to exit through its own protocol, then waits for it.
	void stop()
	{
		if (thread is null)
			return;
		link.submit(`{"id":0,"method":"daemon.shutdown"}` ~ "\n");
		thread.join(false);
		thread = null;
		link.dispose();
	}

	int exitCode() const
	{
		return rc;
	}
}

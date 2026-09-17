/// The core: wiring and lifecycle of every service, and the two ways to run
/// it — on a thread of its own behind the UI, or on the main thread headless.
/// Everything else lives in a package with one responsibility; this file only
/// decides the order things start and stop in.
module photowagon.core.daemon;

import core.thread : Thread;
import core.time : Duration, seconds;
import std.conv : to;
import std.file : mkdirRecurse, write, remove, exists;
import std.path : buildPath;

import vibe.core.core : runTask, runEventLoop, exitEventLoop, sleep;
import vibe.core.log : logInfo, logWarn, logError;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.api.album_api : registerAlbumApi;
import photowagon.core.api.daemon_api : registerDaemonApi;
import photowagon.core.api.device_api : registerDeviceApi;
import photowagon.core.api.edit_api : registerEditApi;
import photowagon.core.api.face_api : registerFaceApi;
import photowagon.core.api.import_api : registerImportApi;
import photowagon.core.api.usb_api : registerUsbApi;
import photowagon.core.api.cast_api : registerCastApi;
import photowagon.core.api.library_api : registerLibraryApi;
import photowagon.core.api.media_api : registerMediaApi;
import photowagon.core.api.memories_api : registerMemoriesApi;
import photowagon.core.api.moments_api : registerMomentsApi;
import photowagon.core.api.p2p_api : registerP2pApi;
import photowagon.core.api.pairing_api : registerPairingApi, ServerControl;
import photowagon.core.api.places_api : registerPlacesApi;
import photowagon.core.api.tags_api : registerTagsApi;
import photowagon.core.config : Config;
import photowagon.core.db.schema : migrate;
import photowagon.core.db.sqlite : Database;
import photowagon.core.faces.repo : FaceRepo;
import photowagon.core.faces.service : FaceService;
import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.handler : RequestHandler;
import photowagon.core.ipc.link : InProcessLink;
import photowagon.core.ipc.protocol : Registry;
import photowagon.core.ipc.server : IpcServer;
import photowagon.core.jobs.scheduler : Scheduler, installScheduler;
import photowagon.core.vision.worker : configureVision, VisionModels, releaseVision;
import photowagon.core.p2p.ipc : IpcOverP2p;
import photowagon.core.p2p.blobpush : BlobStash, BlobOverP2p;
import photowagon.core.library.albums : AlbumRepo;
import photowagon.core.library.dates : DateTree;
import photowagon.core.library.memories : MemoriesService;
import photowagon.core.library.moments : MomentsService;
import photowagon.core.usb.watcher : UsbWatcher;
import photowagon.core.casting.service : CastService;
import photowagon.core.library.kindjob : KindService;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.library.places : Geocoder, PlaceService;
import photowagon.core.library.scenes : SceneService;
import photowagon.core.library.placemodel : PlaceModel;
import photowagon.core.library.keywords : KeywordService;
import photowagon.core.metadata.filetags : FileTagWriter, applyFileSubjects;
import photowagon.core.library.roots : RootRepo;
import photowagon.core.p2p.devices : DeviceRepo, PairingManager;
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
	private UsbWatcher usbWatcher; // null when headless
	private CastService castSvc;   // null when headless
	private Database db;
	private IpcServer ipc;
	private string ipcAddress;
	private IpcServer lan;      // the phones' listener next to a loopback --port one
	private ushort lanPort;
	private Registry registry;
	private Events events;
	private string token;
	private ushort ipcPortInUse;
	private RequestHandler inproc;
	private FiberGroup own;
	private Indexer indexer;
	private FaceService facesService;
	private KindService kinds;
	private bool taggingArmed;   // a deferred "start tagging when quiet" retry is scheduled
	private PlaceService places;
	private SceneService scenes;
	private PlaceModel placeModel;
	private FileTagWriter fileTags;
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
		installScheduler(new Scheduler(cfg.heavyJobs));
		configureVision(VisionModels(cfg.clipModel, cfg.yunetModel, cfg.sfaceModel));
		db = new Database(cfg.dbPath);
		migrate(db);
		auto store = new ContentStore(cfg.storeDir);
		events = new Events;
		token = loadOrCreateToken(buildPath(cfg.dataDir, "pair.token"));
		auto roots = new RootRepo(db);
		auto photos = new PhotoRepo(db, store);
		auto dates = new DateTree(db, store);
		auto albums = new AlbumRepo(db);
		auto memories = new MemoriesService(db, store, photos);
		auto moments = new MomentsService(db, store, photos);
		indexer = new Indexer(cfg, photos, events);
		auto faceRepo = new FaceRepo(db);
		facesService = new FaceService(cfg, db, faceRepo, photos, store, events);
		kinds = new KindService(db, photos, faceRepo, store, events);
		// index → kinds → faces: faces are only looked for in photographs
		try
		{
			import photowagon.core.library.datefix : fixDates;
			fixDates(db, events);
		}
		catch (Exception e)
			logWarn("dates: pass failed: %s", e.msg);
		// places: the cities of the photos with GPS, at start and after every index run
		places = new PlaceService(db, Geocoder.builtin(), store, events);
		try
			places.geocodePending();
		catch (Exception e)
			logWarn("places: pass failed: %s", e.msg);
		indexer.onDone = () {
			try
				places.geocodePending();
			catch (Exception e)
				logWarn("places: pass failed: %s", e.msg);
			startTaggingWhenQuiet();
		};
		scenes = new SceneService(cfg, db, photos, store, events);
		kinds.onDone = () { facesService.start(); scenes.start(); };   // both look only at photographs
		// learned places: recognise where a photo was taken by how it looks (no GPS needed),
		// once the CLIP embeddings are current — and again whenever the user names a new place
		placeModel = new PlaceModel(db, events);
		scenes.onDone = () { placeModel.start(); };

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

		auto deviceRepo = new DeviceRepo(db);
		auto pairingMgr = new PairingManager;
		registry = new Registry;
		registerDaemonApi(registry, cfg, node, &requestStop);
		registerDeviceApi(registry, deviceRepo, events, pairingMgr);
		registerPairingApi(registry, this);
		registerLibraryApi(registry, roots, photos, dates, indexer, events, kinds, () { facesService.start(); });
		registerMediaApi(registry, photos, store);
		auto blobStash = new BlobStash;
		registerImportApi(registry, cfg, roots, photos, indexer, blobStash);
		registerFaceApi(registry, faceRepo, facesService, store, events);
		registerAlbumApi(registry, albums, photos, sharing);
		registerMemoriesApi(registry, memories, photos);
		registerMomentsApi(registry, moments, photos);
		registerPlacesApi(registry, places);
		// tags in the files: what the user says goes into the XMP / IPTC keywords, what a
		// file brings along comes into the library
		fileTags = new FileTagWriter(db, events);
		auto keywords = new KeywordService(db, store, events);
		keywords.onUserChange = (const(long)[] ids) { fileTags.enqueue(ids); };
		scenes.onUserChange = (const(long)[] ids) { fileTags.enqueue(ids); };
		places.onUserChange = (const(long)[] ids) { fileTags.enqueue(ids); if (placeModel) placeModel.relearn(); };
		indexer.onFileSubjects = (long id, string[] subjects) { applyFileSubjects(db, id, subjects); };
		registerTagsApi(registry, scenes, keywords, photos, fileTags);
		registerEditApi(registry, cfg, photos, store, events, (string path) {
			import std.string : startsWith;
			foreach (root; roots.list())
				if (path.startsWith(root.path))
					indexer.start(root.id, root.path);
		});
		registerP2pApi(registry, node, sharing);
		// USB import from a plugged-in phone (like Photos): desktop-UI only.
		if (link !is null)
			usbWatcher = new UsbWatcher(cfg, events, roots, indexer);
		registerUsbApi(registry, usbWatcher);
		// Cast a photo to a TV (Chromecast / Cast-enabled TV): desktop-UI only.
		if (link !is null)
			castSvc = new CastService(photos);
		registerCastApi(registry, castSvc);
		if (node !is null)
		{
			new IpcOverP2p(node.host, registry, events, token, deviceRepo, pairingMgr);   // the phone's way in over libp2p
			new BlobOverP2p(node.host, blobStash, deviceRepo);   // the raw-bytes pipe for pushed photos/videos
		}

		if (link !is null)
		{
			inproc = new RequestHandler(registry, &link.deliver);
			events.attach(&link.deliver);
			own.spawn(&pumpLink);
			logInfo("core %s: serving the UI in-process, data in %s", coreVersion, cfg.dataDir);
			if (usbWatcher !is null)
				usbWatcher.start();
		}
		if (cfg.serve)
			startServing(cfg.ipcAddress);

		// pick up changes since last run
		foreach (root; roots.list())
			indexer.start(root.id, root.path);
		kinds.start();
	}

	// ---- ServerControl: the loopback/LAN listener, on demand ------------------------

	ushort startServing(string address)
	{
		// A loopback listener (--port, for tools and tests) does not serve a phone: a
		// second one opens on the LAN, on a port of its own, and the first stays —
		// closing it would drop the very client that asked for the pairing.
		if (ipc !is null && address == "0.0.0.0" && ipcAddress != "0.0.0.0")
		{
			if (lan is null)
			{
				lan = new IpcServer(registry, events, token);
				lanPort = lan.listen("0.0.0.0", 0);
				logInfo("core: also listening for phones on 0.0.0.0:%s", lanPort);
			}
			return lanPort;
		}
		if (ipc !is null)
			return ipcPortInUse;
		ipcAddress = address;
		mkdirRecurse(cfg.runtimeDir);
		ipc = new IpcServer(registry, events, token);
		ipcPortInUse = ipc.listen(address, cfg.ipcPort);
		write(cfg.portFile, ipcPortInUse.to!string ~ "\n");
		logInfo("core %s: ipc on %s:%s (port file %s), data in %s", coreVersion, address, ipcPortInUse, cfg.portFile, cfg.dataDir);
		return ipcPortInUse;
	}

	void stopServing()
	{
		if (lan !is null)
		{
			lan.close();
			lan = null;
			return;
		}
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
		return lan !is null || (ipc !is null && ipcAddress == "0.0.0.0");
	}

	ushort servingPort()
	{
		return lan !is null ? lanPort : ipcPortInUse;
	}

	string pairingToken()
	{
		return token;
	}

	string[] p2pAddrs()
	{
		return node is null ? null : node.addrs;
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

	/// Classification and tagging are a SEPARATE concern from finding photos: the scan
	/// makes a photo appear, the classifiers (kinds → faces → scenes) label it later.
	/// Chaining them meant every batch a phone sync delivered kicked the CLIP and face
	/// workers, which then starved the sync's own requests — "o celular espera o
	/// computador taguear a foto antes de mandar outra". So hold tagging off while the
	/// indexer is still active (photos arriving), and run it once things have been quiet
	/// for a window. On a desktop folder add, the indexer goes quiet fast and this is a
	/// short delay; during a sync burst it waits for the burst to end.
	private enum Duration taggingQuiet = 12.seconds;
	private void startTaggingWhenQuiet()
	{
		if (indexer.activeWithin(taggingQuiet))
		{
			if (!taggingArmed)
			{
				taggingArmed = true;
				runTask(() nothrow {
					try
						sleep(taggingQuiet);
					catch (Exception)
					{
					}
					taggingArmed = false;
					try
						startTaggingWhenQuiet();
					catch (Exception)
					{
					}
				});
			}
			return;
		}
		kinds.start();
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
		if (usbWatcher)
			usbWatcher.stop();
		if (castSvc)
			castSvc.stop();
		own.stopAll();
		if (inproc)
			inproc.close();
		if (ipc)
			ipc.close();
		if (indexer)
			indexer.close();
		if (kinds)
			kinds.close();
		if (facesService)
			facesService.close();
		if (scenes)
			scenes.close();
		if (placeModel)
			placeModel.close();
		if (fileTags)
			fileTags.close();
		releaseVision();
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
		quitOnSignal();   // after runEventLoop installed vibe's SIGTERM / SIGINT handlers, which only stop this loop
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

/// SIGTERM / SIGINT end the whole process — vibe-core's own handlers (installed by
/// runEventLoop on this thread) would only stop the core's loop and leave the Qt
/// window running after a `kill`.
private void quitOnSignal() nothrow @nogc
{
	version (Posix)
	{
		import core.sys.posix.signal : sigaction, sigaction_t, SIGTERM, SIGINT;
		import core.sys.posix.unistd : _exit;

		extern (C) static void quit(int) nothrow @nogc { _exit(0); }
		sigaction_t sa;
		sa.sa_handler = &quit;
		sigaction(SIGTERM, &sa, null);
		sigaction(SIGINT, &sa, null);
	}
}

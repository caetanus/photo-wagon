// Library — the single @QObject the QML sees.
//
// Lists cross to QML as JSON strings, one page at a time (DSide route B); the
// QML does JSON.parse and nothing else. Commands are void @Slots. Every payload
// here mirrors a method in docs/ipc.md; the bridge does the wire work.
//
// With a remote bridge (the mobile app) photos cannot be file:// URLs: the
// thumbnails of a page and the bytes of the open photo are fetched through
// `library.thumbs` / `photo.file` and handed to QML as data: URLs.
module photowagon.ui.backend;

import qtmoc;
import qt.quick.qcoreapplication;
import qt.quick.qtimer : QTimer;
import cppq = qt.quick.qobject;

import std.json;
import std.stdio : writeln, stdout;
import std.string : startsWith, strip;
import std.conv : to;
import std.datetime.systime : Clock;

import photowagon.ui.transport : Bridge;
import photowagon.ui.gridrows : GridRows;

version (WithUi)
{
	/// csrc/clipboard_qt.h: the QMimeData is created in C++ so the clipboard is its only owner.
	/// Desktop only: the phone client (no WithUi) has no file clipboard.
	private extern (C) int pw_clipboard_set_files(const char* uris, const char* gnome, const char* text);
	/// csrc/media_prewarm.h: 1 once Qt Multimedia's start-up probe (run off the GUI thread) is done.
	private extern (C) int pw_media_ready();
}

@QObject class Library
{
    Signal!() pageChanged;
    Signal!() rowsChanged;
    Signal!() anchorRowChanged;
    Signal!() toolsSimilarChanged;
    Signal!() toolsThumbsChanged;
    Signal!() toolsJunkChanged;
    Signal!() mediaReadyChanged;
    /// Desktop: the video backend finished its start-up probe; a MediaPlayer created before
    /// would block the window until it does (the viewer shows the poster meanwhile).
    @Property("mediaReadyChanged") bool mediaReady = false;
    Signal!() toolsFaceChanged;
    /// Tools (desktop): the similar-photos scan {running, done, progress, total, groups?}
    @Property("toolsSimilarChanged") string toolsSimilar = `{}`;
    /// Tools: {scanned, redundant: [{photo, keep}], orphans: [photo]}
    @Property("toolsThumbsChanged") string toolsThumbs = `{}`;
    /// the screenshots or memes grouped by where they came from (tools.junk)
    @Property("toolsJunkChanged") string toolsJunk = `{}`;
    private string junkKind;
    /// Tools: {offset, total, clusters, loose, item?, candidates: [person]}
    @Property("toolsFaceChanged") string toolsFace = `{}`;
    /// The phone grid's rows (a QAbstractListModel built in D, updated by key on every page:
    /// the delegates on screen survive) — `ListView { model: library.rows }`.
    @Property("rowsChanged") cppq.QObject rows;
    /// After setGridColumns: the row now holding the photo that was under the fingers.
    @Property("anchorRowChanged") int anchorRow = -1;
    private GridRows gridRows;
    Signal!() noticeChanged;
    Signal!() placesChanged;
    Signal!() tagsChanged;
    Signal!() keywordsChanged;
    Signal!() presetsChanged;
    Signal!() previewChanged;
    Signal!() presetPreviewsChanged;
    Signal!() tagLabelsChanged;
    Signal!() photoTagsChanged;
    Signal!() placeSuggestionsChanged;
    Signal!() dayMatesChanged;
    Signal!() systemAccentChanged;
    Signal!() datesChanged;
    Signal!() rootsChanged;
    Signal!() albumsChanged;
    Signal!() peersChanged;
    Signal!() peerNamesChanged;
    Signal!() statusChanged;
    Signal!() helloChanged;
    Signal!() currentChanged;
    Signal!() endpointChanged;
    Signal!() pairingChanged;
    Signal!() devicesChanged;
    Signal!() pairingCodeChanged;
    Signal!() pairingRequestChanged;
    Signal!() deviceConnectedChanged;
    Signal!() peopleChanged;
    Signal!() facesChanged;
    Signal!() memoriesChanged;
    Signal!() momentsChanged;
    Signal!() castDevicesChanged;
    Signal!() filterChanged;
    Signal!() suggestionChanged;
    Signal!() statsChanged;
    Signal!() syncChanged;
    Signal!() candidatesChanged;
    Signal!() regionChanged;
    Signal!() originalChanged;
    Signal!() uiStateChanged;

    /// {"total":N,"offset":o,"items":[Photo…]} — accumulated across loadPage calls.
    @Property("pageChanged")    string page   = `{"total":0,"offset":0,"items":[]}`;
    /// {"years":[{year,count,months:[{month,count,days:[{day,count}]}]}]}
    @Property("datesChanged")   string dates  = `{"years":[]}`;
    @Property("rootsChanged")   string roots  = `{"roots":[]}`;
    @Property("albumsChanged")  string albums = `{"albums":[]}`;
    @Property("peersChanged")   string peers  = `{"peerId":"","addrs":[],"peers":[]}`;
    /// {peerId: nickname} — user-given names the Peers panel overlays onto the live peer list.
    @Property("peerNamesChanged") string peerNames = `{}`;
    /// {"connected":bool,"indexing":bool,"text":"…"}
    @Property("statusChanged")  string status = `{"connected":false,"indexing":false,"text":"starting…"}`;
    @Property("helloChanged")   string hello  = `{}`;
    /// A short line the phone shows as a toast (the outcome of an action on a selection);
    /// noticeChanged fires for every notice, even the same text twice.
    @Property("noticeChanged")  string notice = "";
    /// Photo JSON with "prev"/"next" ids added, or "" when nothing is open.
    @Property("currentChanged") string current = "";
    /// PW_SHOT=/path.png makes Main.qml photograph itself there and quit (headless checks).
    @Property("statusChanged") string shotPath = "";
    /// PW_SHOT_OPEN=<id> opens that photo in the viewer before the capture.
    @Property("statusChanged") int shotOpenId = 0;
    /// PW_SHOT_SEND=1 (phone) calls sendAll() before the capture.
    @Property("statusChanged") bool shotSend = false;
    /// PW_SHOT_VIEW=people|days|months|years switches the desktop view before the capture.
    @Property("statusChanged") string shotView = "";
    /// "host:port" of a remote core (mobile), "" when the core is in-process.
    @Property("endpointChanged") string endpoint = "";
    /// True when photos are fetched over the network (no file:// URLs).
    @Property("endpointChanged") bool remote = false;
    /// Phone: whether the computer at `endpoint` is reachable right now.
    @Property("endpointChanged") bool computerConnected = false;
    /// A computer is set up (the phone's pairing), reachable or not.
    @Property("endpointChanged") bool computerPaired = false;
    /// Desktop: {enabled, port, addrs, code, qr:{width, rows}} while a phone may pair.
    @Property("pairingChanged") string pairing = `{"enabled":false}`;
    /// Desktop: the paired phones — {devices:[{peerId, name, state, pairedAt, lastSeen}]}.
    @Property("devicesChanged") string devices = `{"devices":[]}`;
    /// Phone: while first-pairing, {code:"4821"} to show so the desktop can authorize; {} otherwise.
    @Property("pairingCodeChanged") string pairingCode = "{}";
    /// Desktop: a phone knocking to be authorized — {peer, name}; {} when none is waiting.
    @Property("pairingRequestChanged") string pairingRequest = "{}";
    /// USB: a phone just plugged in — {serial, model}; {} when none is waiting or after the choice.
    @Property("deviceConnectedChanged") string deviceConnected = "{}";
    /// {"people":[{id,name,faces,coverUrl}]} — clusters of faces, most photos first.
    @Property("peopleChanged") string people = `{"people":[]}`;
    /// memories.list: {"memories":[{key,kind,title,subtitle,cover,count}]} — the curated strip.
    @Property("memoriesChanged") string memories = `{"memories":[]}`;
    /// moments.list: {"moments":[{key,title,subtitle,cover,count}]} — the timeline as events.
    @Property("momentsChanged") string moments = `{"moments":[]}`;
    /// cast.devices: {"devices":[{name,host,port}]} — the Cast screens on the LAN, when last asked.
    @Property("castDevicesChanged") string castDevices = `{"devices":[]}`;
    /// {"places":[{place,country,count,cover}]} — the cities of the library, most photos first
    @Property("placesChanged") string places = `{"places":[]}`;
    /// places.suggest for the name being typed in "Set Place…": {"places":[{place,country,own}]}
    @Property("placeSuggestionsChanged") string placeSuggestions = `{"places":[]}`;
    /// album.dayMates for the photos being added to an album: {"items":[…]} — same-day suggestions
    @Property("dayMatesChanged") string dayMates = `{"items":[]}`;
    /// The desktop's accent colour as "#rrggbb" (GNOME accent-color → Adwaita), or "" when
    /// unknown / not GNOME. The "System" theme uses it so the accent matches the desktop exactly.
    @Property("systemAccentChanged") string systemAccent = "";
    /// tags.list: {"scene":[{tag,count,cover}],"mood":[…],"weather":[…],"holiday":[…],"available"} — most photos first
    @Property("tagsChanged") string tags = `{"scene":[],"mood":[],"weather":[],"holiday":[],"available":false}`;
    /// tags.labels: {"scene":[names],"mood":[names],"weather":[…],"holiday":[…]} — what the user can pick in the menu
    @Property("tagLabelsChanged") string tagLabels = `{"scene":[],"mood":[],"weather":[],"holiday":[]}`;
    /// keywords.list: {"keywords":[{keyword,count,cover}]} — the user's own tags, most photos first
    @Property("keywordsChanged") string keywords = `{"keywords":[]}`;
    /// edit.presets: {"presets":[{name, edits}]} — the filters of the edit panel
    @Property("presetsChanged") string presets = `{"presets":[]}`;
    /// the last photo.preview: {"id","url","width","height","seq"}
    @Property("previewChanged") string preview = `{"id":0}`;
    /// photo.presetPreviews of the photo being edited: {"id","items":[{name,url,edits}]}
    @Property("presetPreviewsChanged") string presetPreviews = `{"id":0,"items":[]}`;
    /// photo.tags of the open photo: {"id", <group>: tag, "by": {group: auto|date|user}, "scores": {group: [{tag,prob}]}}
    @Property("photoTagsChanged") string photoTags = `{"id":0}`;
    /// {"photoId":N,"faces":[{id,x,y,w,h,personId,name,thumbUrl}]} for the open photo.
    @Property("facesChanged") string faces = `{"photoId":0,"faces":[]}`;
    /// The person the grid is filtered to (0 = none).
    @Property("peopleChanged") int personFilter = 0;
    /// {"total":N,"kinds":{"photo":n,"screenshot":n,"meme":n}} — what the library holds.
    @Property("statsChanged") string stats = `{"total":0,"kinds":{}}`;
    /// After a naming: {"person":{…},"candidates":[{…,"similarity"}]} of people who may be the same, or "{}".
    @Property("suggestionChanged") string suggestion = "{}";
    /// photo.region for the zoomed viewer: {id, x, y, w, h, url}
    @Property("regionChanged") string region = `{"id":0}`;
    /// the phone's zoomed viewer: the photo's ORIGINAL as a local file {id, url} — its own file,
    /// or the computer's original fetched raw over the piece pipe (photo.download)
    @Property("originalChanged") string original = `{"id":0}`;
    /// face.candidates for the face being named: {faceId, people: [{id, name, faces, coverUrl, similarity}]}
    @Property("candidatesChanged") string candidates = `{"faceId":0,"people":[]}`;
    /// The window's own remembered state (geometry, which sections are folded, the last view):
    /// the QML reads it at startup and writes it back through saveUiState. Kept in a local
    /// config file, not the library, since it is this desktop's preference, not shared data.
    @Property("uiStateChanged") string uiState = "{}";
    /// Phone: parsed library.syncStatus — {enabled, connected, active, pending, total, done, sent, skipped, failed, error}
    @Property("syncChanged") string sync = `{"enabled":false,"connected":false,"active":false,"pending":0,"total":0,"done":0,"sent":0,"skipped":0,"failed":0,"error":null}`;
    /// {"year","month","day","personId","albumId","rootId","favorites"} — what the page shows.
    @Property("filterChanged") string filter = `{"year":0,"month":0,"day":0,"personId":0,"albumId":0,"rootId":0,"favorites":false,"kind":"","text":""}`;

    private Bridge client;
    private string[long] thumbCache; // id → data: URL, remote only
    private JSONValue[] items;
    private long total;
    private int fYear, fMonth, fDay;
    private long fPerson;
    private long fAlbum, fRoot;
    private bool fFavorites;
    private string fKind;
    private string fText;
    private string fPlace;
    private string fCountry;
    private string fTagGroup;
    private string fTag;
    private string fMemory;   // a memory key: pages through memories.page instead of library.page
    private string fMoment;   // a moment key: pages through moments.page instead of library.page
    private string fKeyword;
    private long fSimilar;   // photos that look like this one (photo.similar), instead of library.page
    private string fSemantic;   // free-text search (search.combined: file/OCR + CLIP), instead of library.page
    private bool searchIsNew;   // fSemantic was just submitted: its first reload shows "searching"
    private long lastTimelineHns;   // Clock.currStdTime of the last library.changed refresh (coalescing)
    /// Screenshots and memes stay out of the library timeline (they have their own
    /// views under Media Types); an album, a search or an explicit kind shows everything.
    private bool onlyPhotos = true;

    private string kindParam()
    {
        if (fKind.length) return fKind;
        // the library's own view: photos AND videos (videos have their own kind since they
        // were added, and a "photo" default had hidden every one of them); no screenshots/memes
        if (onlyPhotos && !fAlbum && !fText.length && !fPlace.length && !fTag.length && !fKeyword.length) return "media";
        return null;
    }
    private long openId; // photo being opened/shown; faces answers for others are dropped
    private long pageEpoch;   // bumped by each new listing (offset 0): older page replies are dropped
    private int pageLimit = 240;
    private bool indexing;
    private string progressText;

    /// Second half of construction: runs after newQObject registered us.
    /// Where the window remembers its state (geometry, folded sections, last view).
    private string uiStatePath()
    {
        import std.process : environment;
        import std.path : buildPath, expandTilde;

        immutable cfg = environment.get("XDG_CONFIG_HOME", expandTilde("~/.config"));
        return buildPath(cfg, "photowagon", "ui-state.json");
    }

    /// QML calls this whenever the window state changes (geometry, a fold, the view).
    @Slot void saveUiState(string json)
    {
        import std.file : write, mkdirRecurse, FileException;
        import std.path : dirName;

        if (json == uiState)
            return;
        uiState = json;
        try
        {
            mkdirRecurse(uiStatePath().dirName);
            write(uiStatePath(), json);
        }
        catch (Exception e)
            report("saveUiState", JSONValue(e.msg));
        uiStateChanged.emit();
    }

    void start(Bridge bridge)
    {
        import std.process : environment;
        import std.file : exists, readText;

        if (gridRows is null)
        {
            gridRows = new GridRows();   // `new`, not newQObject: a QtdWidget (see the dside skill)
            rows = cppq.QObject.wrap(qobjOf(gridRows));
            rowsChanged.emit();
        }

        try
            if (uiStatePath().exists)
            {
                uiState = readText(uiStatePath());
                uiStateChanged.emit();
            }
        catch (Exception)
        {
        }
        shotPath = environment.get("PW_SHOT", "");
        shotOpenId = environment.get("PW_SHOT_OPEN", "0").to!int;
        shotSend = environment.get("PW_SHOT_SEND", "") == "1";
        shotView = environment.get("PW_SHOT_VIEW", "");
        client = bridge;
        remote = client.remote();
        endpoint = client.endpoint();
        endpointChanged.emit();
        client.onEvent = &onEvent;
        client.onConnected = &onLink;
        client.start();
    }

    /// Mobile: point the bridge at a core on the network and reconnect.
    @Slot void setEndpoint(string host, int port)
    {
        client.setEndpoint(host.strip(), cast(ushort) port);
        endpoint = client.endpoint();
        endpointChanged.emit();
    }

    // ---- slots (QML → D) -------------------------------------------------------

    @Slot void addRoot(string path)
    {
        auto p = path.strip();
        if (p.startsWith("file://"))
            p = p[7 .. $];
        if (p.length == 0)
            return;
        JSONValue params = ["path": p];
        client.request("library.addRoot", params, (r, e) {
            if (e.type != JSONType.null_) { report("addRoot", e); return; }
            loadRoots();
        });
    }

    /// offset 0 restarts the list with a date filter (0 = none); other offsets load more.
    @Slot void loadPage(int offset, int limit, int year, int month, int day)
    {
        if (offset == 0)
            filterDate(year, month, day);
        else
            reload(offset, limit);
    }

    /// The next page of the current filter.
    @Slot void loadMore()
    {
        reload(cast(int) items.length, pageLimit);
    }

    // ---- filters: each one is a view of the library; setting one clears the others ----

    @Slot void showAll()
    {
        clearFilters();
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    /// A year, a month or a day (0 = any). Keeps a person/album/root filter, but leaves
    /// the alternate result views (search / similar / moment) — a date is a normal page.
    @Slot void filterDate(int year, int month, int day)
    {
        fSemantic = null;
        fSimilar = 0;
        fMoment = null;
        fYear = year; fMonth = year ? month : 0; fDay = month ? day : 0;
        publishFilter();
        reload(0, pageLimit);
    }

    /// Photos of one person (0 clears).
    @Slot void filterPerson(int personId)
    {
        clearFilters();
        fPerson = personId;
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    @Slot void filterAlbum(int albumId)
    {
        clearFilters();
        fAlbum = albumId;
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    @Slot void filterRoot(int rootId)
    {
        clearFilters();
        fRoot = rootId;
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    @Slot void filterFavorites()
    {
        clearFilters();
        fFavorites = true;
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    /// Photographs, screenshots or memes only ("" = everything).
    @Slot void filterKind(string kind)
    {
        clearFilters();
        fKind = kind;
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    /// Free-text search: file name, folder, the OCR text inside a picture, and CLIP
    /// natural-language matches, blended by search.combined ("" = everything).
    @Slot void filterSearch(string q)
    {
        import std.string : strip;
        clearFilters();
        fSemantic = q.strip();
        searchIsNew = fSemantic.length > 0;
        publishFilter();   // the query is the view's title (and what "back" clears)
        if (!fSemantic.length)
        {
            reload(0, pageLimit);
            loadDates();
            return;
        }
        reload(0, pageLimit);
    }

    /// Photos of one place ("" clears).
    @Slot void filterPlace(string place, string country)
    {
        import std.string : strip;
        clearFilters();
        fPlace = place.strip();
        fCountry = country.strip();
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    /// Open a curated memory (see memories.list): its photos in their own paged view.
    @Slot void filterMemory(string key)
    {
        clearFilters();
        fMemory = key;
        publishFilter();
        reload(0, pageLimit);
    }

    /// Open one moment (see moments.list): the photos in its time window.
    @Slot void filterMoment(string key)
    {
        clearFilters();
        fMoment = key;
        publishFilter();
        reload(0, pageLimit);
    }

    /// Photos tagged with one scene / mood ("" clears).
    @Slot void filterTag(string group, string tag)
    {
        import std.string : strip;
        clearFilters();
        fTagGroup = group;
        fTag = tag.strip();
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    /// Photos carrying one of the user's own tags ("" clears).
    @Slot void filterKeyword(string keyword)
    {
        import std.string : strip;
        clearFilters();
        fKeyword = keyword.strip();
        publishFilter();
        reload(0, pageLimit);
        loadDates();
    }

    /// The photos that look like `id` (CLIP nearest neighbours), as the page.
    @Slot void filterSimilar(int id)
    {
        clearFilters();
        fSimilar = id;
        publishFilter();
        reload(0, pageLimit);
    }

    /// Writes the library's tags into these files ("[]" = every tagged photo).
    @Slot void writeTagsToFiles(string photoIdsJson)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = ids;
        client.request("files.writeTags", params, (r, e) {
            if (e.type != JSONType.null_) { report("files.writeTags", e); return; }
            setStatus(true, true, "writing tags into " ~ r["queued"].integer.to!string ~ " files…");
        });
    }

    @Slot void loadKeywords()
    {
        client.request("keywords.list", (r, e) {
            if (e.type != JSONType.null_) return;
            keywords = r.toString();
            keywordsChanged.emit();
        });
    }

    /// Adds the comma-separated `text` as tags to these photos.
    @Slot void addKeywords(string photoIdsJson, string text)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = ids;
        params["keywords"] = text;
        client.request("photo.addKeywords", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.addKeywords", e); return; }
            setStatus(true, indexing, "tagged");
        });
    }

    @Slot void removeKeyword(string photoIdsJson, string keyword)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = ids;
        params["keyword"] = keyword;
        client.request("photo.removeKeyword", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.removeKeyword", e); return; }
        });
    }

    // ---- editing --------------------------------------------------------------------

    @Slot void loadPresets()
    {
        client.request("edit.presets", (r, e) {
            if (e.type != JSONType.null_) return;
            presets = r.toString();
            presetsChanged.emit();
        });
    }

    private long previewSeq;

    /// A preview of `editsJson` on photo `id` (≤ 1600 px), answered through `preview`.
    @Slot void previewEdits(int id, string editsJson)
    {
        JSONValue params = JSONValue.emptyObject;
        params["id"] = id;
        try
            params["edits"] = parseJSON(editsJson);
        catch (JSONException)
            params["edits"] = JSONValue.emptyObject;
        immutable seq = ++previewSeq;
        client.request("photo.preview", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.preview", e); return; }
            if (seq != previewSeq || id != openId) return;   // a newer request is on its way
            r["id"] = id;
            r["seq"] = seq;
            preview = r.toString();
            previewChanged.emit();
        });
    }

    /// Every filter on photo `id`, small, with the geometry of `editsJson` kept.
    @Slot void loadPresetPreviews(int id, string editsJson)
    {
        JSONValue params = JSONValue.emptyObject;
        params["id"] = id;
        try
            params["edits"] = parseJSON(editsJson);
        catch (JSONException)
            params["edits"] = JSONValue.emptyObject;
        params["maxEdge"] = 160;
        client.request("photo.presetPreviews", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.presetPreviews", e); return; }
            if (id != openId) return;
            r["id"] = id;
            presetPreviews = r.toString();
            presetPreviewsChanged.emit();
        });
    }

    /// Keeps the result in the library (the file is untouched).
    @Slot void applyEdits(int id, string editsJson)
    {
        JSONValue params = JSONValue.emptyObject;
        params["id"] = id;
        try
            params["edits"] = parseJSON(editsJson);
        catch (JSONException)
            params["edits"] = JSONValue.emptyObject;
        setStatus(true, true, "saving the edit…");
        client.request("photo.applyEdits", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.applyEdits", e); return; }
            setStatus(true, indexing, "edit saved");
            if (id == openId) openPhoto(id);
        });
    }

    @Slot void revertEdits(int id)
    {
        JSONValue params = ["id": JSONValue(id)];
        client.request("photo.revertEdits", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.revertEdits", e); return; }
            setStatus(true, indexing, "back to the original");
            if (id == openId) openPhoto(id);
        });
    }

    /// A JPEG next to the original, indexed like any other file.
    @Slot void saveCopy(int id, string editsJson)
    {
        JSONValue params = JSONValue.emptyObject;
        params["id"] = id;
        try
            params["edits"] = parseJSON(editsJson);
        catch (JSONException)
            params["edits"] = JSONValue.emptyObject;
        setStatus(true, true, "writing the copy…");
        client.request("photo.saveCopy", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.saveCopy", e); return; }
            setStatus(true, indexing, "copy saved: " ~ r["path"].str);
        });
    }

    @Slot void loadTags()
    {
        client.request("tags.list", (r, e) {
            if (e.type != JSONType.null_) return;
            tags = r.toString();
            tagsChanged.emit();
        });
    }

    @Slot void loadTagLabels()
    {
        client.request("tags.labels", (r, e) {
            if (e.type != JSONType.null_) return;
            tagLabels = r.toString();
            tagLabelsChanged.emit();
        });
    }

    /// The scene / mood of one photo with the runner-up scores, for the info panel.
    @Slot void loadPhotoTags(int id)
    {
        JSONValue params = ["id": JSONValue(id)];
        client.request("photo.tags", params, (r, e) {
            if (e.type != JSONType.null_ || id != openId) return;
            r["id"] = id;
            photoTags = r.toString();
            photoTagsChanged.emit();
        });
    }

    /// The user's word on the scene or mood of a selection ("" = nothing in particular).
    @Slot void setTag(string photoIdsJson, string group, string tag)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = ids;
        params["group"] = group;
        params["tag"] = tag;
        client.request("photo.setTag", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.setTag", e); return; }
            setStatus(true, indexing, group ~ (tag.length ? " set" : " cleared"));
            reload(0, cast(int) (items.length > pageLimit ? (items.length > 2000 ? 2000 : items.length) : pageLimit));
            if (openId)
            {
                loadPhotoTags(cast(int) openId);
                openPhoto(cast(int) openId);
            }
        });
    }

    @Slot void loadPlaces()
    {
        client.request("places.list", (r, e) {
            if (e.type != JSONType.null_) return;
            places = r.toString();
            placesChanged.emit();
        });
    }

    @Slot void loadMemories()
    {
        client.request("memories.list", (r, e) {
            if (e.type != JSONType.null_) return;
            memories = r.toString();
            memoriesChanged.emit();
        });
    }

    @Slot void loadMoments()
    {
        client.request("moments.list", (r, e) {
            if (e.type != JSONType.null_) return;
            moments = r.toString();
            momentsChanged.emit();
        });
    }

    /// Ask which Cast screens are on the network (populates `castDevices`).
    @Slot void loadCastDevices()
    {
        client.request("cast.devices", (r, e) {
            if (e.type != JSONType.null_) { report("cast.devices", e); return; }
            castDevices = r.toString();
            castDevicesChanged.emit();
        });
    }

    /// Throw photo `id` onto a screen (Chromecast or DLNA).
    @Slot void castTo(string host, int port, string kind, string control, int id)
    {
        JSONValue params = ["host": JSONValue(host), "port": JSONValue(port),
            "kind": JSONValue(kind), "control": JSONValue(control), "id": JSONValue(id)];
        client.request("cast.photo", params, (r, e) {
            if (e.type != JSONType.null_) { report("cast.photo", e); return; }
        });
    }

    /// Start a looping slideshow on a screen, one photo every 5 s. `photoIdsJson` is a
    /// JSON array of ids to play; "" (or "[]") plays the whole library, in time order.
    @Slot void castSlideshow(string host, int port, string kind, string control, string photoIdsJson)
    {
        JSONValue params = ["host": JSONValue(host), "port": JSONValue(port),
            "kind": JSONValue(kind), "control": JSONValue(control), "intervalMs": JSONValue(5000)];
        if (photoIdsJson.length)
        {
            try
            {
                auto ids = parseJSON(photoIdsJson);
                if (ids.type == JSONType.array && ids.array.length)
                    params["photoIds"] = ids;
            }
            catch (JSONException) { }
        }
        client.request("cast.slideshow", params, (r, e) {
            if (e.type != JSONType.null_) { report("cast.slideshow", e); return; }
        });
    }

    @Slot void castNext() { client.request("cast.next", (r, e) { cast(void) r; cast(void) e; }); }
    @Slot void castPrev() { client.request("cast.prev", (r, e) { cast(void) r; cast(void) e; }); }
    @Slot void castPause() { client.request("cast.pause", (r, e) { cast(void) r; cast(void) e; }); }
    @Slot void castResume() { client.request("cast.resume", (r, e) { cast(void) r; cast(void) e; }); }

    @Slot void castStop()
    {
        client.request("cast.stop", (r, e) { cast(void) r; cast(void) e; });
    }

    /// Photos from the same day as `photoIdsJson` (a JSON array) → dayMates, for the
    /// "add the rest of that day too?" suggestion in the Add-to-Album dialog.
    @Slot void loadDayMates(string photoIdsJson)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        if (ids.type != JSONType.array || ids.array.length == 0)
        {
            dayMates = `{"items":[]}`;
            dayMatesChanged.emit();
            return;
        }
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = ids;
        client.request("album.dayMates", params, (r, e) {
            if (e.type != JSONType.null_) { report("album.dayMates", e); return; }
            dayMates = r.toString();
            dayMatesChanged.emit();
        });
    }

    /// Read the desktop's accent colour (GNOME `accent-color`) → systemAccent, as the
    /// matching Adwaita hex. A cheap one-shot at startup; QML calls it, and can re-call
    /// it to pick up a change. Silent (and clears to "") when there is no GNOME setting.
    @Slot void refreshSystemAccent()
    {
        import std.process : execute;
        import std.string : strip, toLower;

        string hex = "";
        try
        {
            auto r = execute(["gsettings", "get", "org.gnome.desktop.interface", "accent-color"]);
            if (r.status == 0)
            {
                auto s = r.output.strip;
                if (s.length >= 2 && s[0] == '\'' && s[$ - 1] == '\'')
                    s = s[1 .. $ - 1];
                hex = adwaitaAccentHex(s.toLower);
            }
        }
        catch (Exception)
        {
        }
        if (hex != systemAccent)
        {
            systemAccent = hex;
            systemAccentChanged.emit();
        }
    }

    /// GNOME 47+ named accent → the libadwaita @accent_bg_color hex.
    private static string adwaitaAccentHex(string name)
    {
        switch (name)
        {
            case "blue":   return "#3584e4";
            case "teal":   return "#2190a4";
            case "green":  return "#3a944a";
            case "yellow": return "#c88800";
            case "orange": return "#ed5b00";
            case "red":    return "#e62d42";
            case "pink":   return "#d56199";
            case "purple": return "#9141ac";
            case "slate":  return "#6f8396";
            default:       return "";
        }
    }

    /// The user's word on where a selection was taken ("" clears).
    @Slot void setPlace(string photoIdsJson, string place, string country)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = ids;
        params["place"] = place;
        params["country"] = country;
        client.request("photo.setPlace", params, (r, e) {
            if (e.type != JSONType.null_) { report("photo.setPlace", e); return; }
            setStatus(true, indexing, place.length ? "place set" : "place cleared");
            reload(0, cast(int) (items.length > pageLimit ? (items.length > 2000 ? 2000 : items.length) : pageLimit));
        });
    }

    /// Cities for the name being typed → placeSuggestions.
    @Slot void suggestPlaces(string q)
    {
        JSONValue params = JSONValue.emptyObject;
        params["q"] = q;
        client.request("places.suggest", params, (r, e) {
            if (e.type != JSONType.null_) return;
            placeSuggestions = r.toString();
            placeSuggestionsChanged.emit();
        });
    }

    /// The user's word on what a picture is.
    @Slot void setKind(int id, string kind)
    {
        JSONValue params = ["id": JSONValue(id), "kind": JSONValue(kind)];
        client.request("photo.setKind", params, (r, e) {
            if (e.type != JSONType.null_) { report("setKind", e); return; }
            foreach (ref it; items)
                if (it["id"].integer == id)
                    it = r;
            publishPage();
            if (current.length && parseJSON(current)["id"].integer == id)
            {
                auto cur = parseJSON(current);
                cur["kind"] = r["kind"];
                cur["kindBy"] = r["kindBy"];
                current = cur.toString();
                currentChanged.emit();
            }
            loadStats();
        });
    }

    @Slot void loadStats()
    {
        client.request("library.stats", (r, e) {
            if (e.type != JSONType.null_) return;
            stats = r.toString();
            statsChanged.emit();
        });
    }

    private void clearFilters()
    {
        fYear = fMonth = fDay = 0;
        fPerson = fAlbum = fRoot = 0;
        fFavorites = false;
        fKind = null;
        fText = null;
        fPlace = fCountry = null;
        fTagGroup = fTag = null;
        fKeyword = null;
        fSimilar = 0;
        fSemantic = null;
        fMemory = null;
        fMoment = null;
    }

    private void publishFilter()
    {
        JSONValue f = JSONValue.emptyObject;
        f["year"] = fYear; f["month"] = fMonth; f["day"] = fDay;
        f["personId"] = fPerson; f["albumId"] = fAlbum; f["rootId"] = fRoot;
        f["favorites"] = fFavorites;
        f["kind"] = fKind is null ? "" : fKind;
        f["text"] = fText is null ? "" : fText;
        f["place"] = fPlace is null ? "" : fPlace;
        f["country"] = fCountry is null ? "" : fCountry;
        foreach (g; ["scene", "mood", "weather", "holiday"])
            f[g] = fTagGroup == g && fTag !is null ? fTag : "";
        f["keyword"] = fKeyword is null ? "" : fKeyword;
        f["similarTo"] = fSimilar;
        f["search"] = fSemantic is null ? "" : fSemantic;   // the free-text search on screen
        filter = f.toString();
        filterChanged.emit();
        if (personFilter != cast(int) fPerson)
        {
            personFilter = cast(int) fPerson;
            peopleChanged.emit();
        }
    }

    private void setPersonFilter(long id)
    {
        fPerson = id;
        publishFilter();
    }

    @Slot void toggleFavorite(int id)
    {
        bool on = true;
        foreach (ref it; items)
            if (it["id"].integer == id && "favorite" in it)
                on = !it["favorite"].boolean;
        JSONValue params = ["id": JSONValue(id), "on": JSONValue(on)];
        client.request("photo.favorite", params, (r, e) {
            if (e.type != JSONType.null_) { report("favorite", e); return; }
            foreach (ref it; items)
                if (it["id"].integer == id)
                    it["favorite"] = on;
            publishPage();
            if (current.length && parseJSON(current)["id"].integer == id)
            {
                auto cur = parseJSON(current);
                cur["favorite"] = on;
                current = cur.toString();
                currentChanged.emit();
            }
        });
    }

    /// Adds photos (a JSON array of ids) to an existing album.
    @Slot void addToAlbum(int albumId, string photoIdsJson)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["id"] = albumId;
        params["photoIds"] = ids;
        client.request("album.addPhotos", params, (r, e) {
            if (e.type != JSONType.null_) { report("album.addPhotos", e); tell(errorText(e)); return; }
            loadAlbums();
            setStatus(true, indexing, "added to the album");
            tell(albumOutcome(r, "Added to the album"));
        });
    }

    /// Phone: the outcome of an album action on photos (the phone core's counts, if any).
    private static string albumOutcome(JSONValue r, string done)
    {
        import std.conv : to;

        long num(string k) { return r.type == JSONType.object && k in r && r[k].type == JSONType.integer ? r[k].integer : 0; }
        string s = done;
        if (num("added") > 0)
            s = done ~ " (" ~ num("added").to!string ~ (num("added") == 1 ? " photo)" : " photos)");
        if (num("sent") > 0)
            s ~= " · " ~ num("sent").to!string ~ " sent to the computer first";
        if (num("failed") > 0)
            s ~= " · " ~ num("failed").to!string ~ " couldn't be added";
        return s;
    }

    private static string errorText(JSONValue e)
    {
        return e.type == JSONType.object && "message" in e && e["message"].type == JSONType.string
            ? e["message"].str : "that didn't work";
    }

    private void tell(string text)
    {
        notice = text;
        noticeChanged.emit();
    }

    /// Phone: several photos to the share sheet at once (a JSON array of ids).
    @Slot void sharePhotos(string photoIdsJson)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            return;
        tell("Preparing " ~ (ids.type == JSONType.array && ids.array.length == 1 ? "the photo" : "the photos") ~ "…");
        client.request("photo.shareMany", JSONValue(["ids": ids]), (r, e) {
            if (e.type != JSONType.null_) { report("share", e); tell(errorText(e)); return; }
            import std.conv : to;
            if (r.type == JSONType.object && "missing" in r && r["missing"].type == JSONType.integer && r["missing"].integer > 0)
                tell(r["missing"].integer.to!string ~ " of them aren't available right now and were left out");
        });
    }

    /// Phone: send the chosen photos (a JSON array of the phone's own ids) to the computer,
    /// one after another.
    @Slot void sendPhotosToComputer(string photoIdsJson)
    {
        import std.conv : to;

        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            return;
        if (ids.type != JSONType.array || ids.array.length == 0)
            return;
        auto list = ids.array;
        size_t ok, bad;
        void step(size_t i)
        {
            if (i == list.length)
            {
                tell(bad == 0 ? (ok == 1 ? "Sent to the computer" : ok.to!string ~ " photos sent to the computer")
                    : ok.to!string ~ " sent · " ~ bad.to!string ~ " couldn't be sent");
                setStatus(client.connected(), indexing, "sent to the computer");
                // the "on the computer" marks (sending does not change the listing's order)
                reload(0, cast(int) (items.length > pageLimit ? (items.length > 2000 ? 2000 : items.length) : pageLimit));
                return;
            }
            setStatus(true, indexing, "sending " ~ (i + 1).to!string ~ " of " ~ list.length.to!string ~ "…");
            client.request("photo.upload", JSONValue(["id": list[i]]), (r, e) {
                if (e.type == JSONType.null_) ok++; else bad++;
                step(i + 1);
            });
        }
        tell(list.length == 1 ? "Sending to the computer…" : "Sending " ~ list.length.to!string ~ " photos to the computer…");
        step(0);
    }

    /// `refresh`: the listing on screen is being brought up to date (a library.changed),
    /// not a new one opened — the phone core then waits for the computer instead of
    /// answering with its own photos first, which shrank the grid and threw the scroll away.
    private void reload(int offset, int limit, bool refresh = false)
    {
        if (fSemantic.length)
        {
            if (offset > 0)
                return;   // one page: the blended search result
            JSONValue sp = JSONValue.emptyObject;
            sp["q"] = fSemantic;
            sp["limit"] = 200;
            immutable asked = fSemantic;
            // until the answer to a NEW query: an honest "searching", not the previous query's
            // outcome (a background refresh of the same query keeps its results on screen)
            if (searchIsNew)
            {
                searchIsNew = false;
                items.length = 0;
                JSONValue pending = JSONValue.emptyObject;
                pending["total"] = 0;
                pending["offset"] = 0;
                pending["items"] = JSONValue.emptyArray;
                pending["searching"] = true;
                page = pending.toString();
                if (gridRows !is null)
                    gridRows.update(items);   // the grid shows what the page does
                pageChanged.emit();
            }
            client.request("search.combined", sp, (r, e) {
                if (fSemantic != asked) return;   // a newer query is in flight
                if (isSuperseded(e)) return;      // a newer listing took the phone core's place
                items.length = 0;
                JSONValue pg = JSONValue.emptyObject;
                if (e.type != JSONType.null_)
                {
                    report("search.combined", e);
                    pg["error"] = "message" in e ? e["message"] : JSONValue("search failed");
                }
                else
                {
                    foreach (it; r["items"].array)
                        items ~= it;
                    // the phone says where it searched: the computer's library, or only its
                    // own file names (offline)
                    if ("scope" in r)
                        pg["scope"] = r["scope"];
                    if ("reason" in r)
                        pg["reason"] = r["reason"];
                }
                pg["total"] = items.length;
                pg["offset"] = items.length;   // the whole result: nothing more to load
                pg["items"] = JSONValue(items);
                page = pg.toString();
                if (gridRows !is null)
                    gridRows.update(items);   // the grid shows what the page does
                pageChanged.emit();
            });
            return;
        }
        if (fSimilar)
        {
            if (offset > 0)
                return;   // one page: the nearest neighbours
            items.length = 0;
            JSONValue sp = JSONValue.emptyObject;
            sp["id"] = fSimilar;
            sp["limit"] = 120;
            client.request("photo.similar", sp, (r, e) {
                if (e.type != JSONType.null_) { report("photo.similar", e); return; }
                if (!fSimilar) return;
                items.length = 0;   // one answer, not the sum of two in flight
                foreach (it; r["items"].array)
                    items ~= it;
                JSONValue pg = JSONValue.emptyObject;
                pg["total"] = items.length;
                pg["offset"] = items.length;   // the whole result: nothing more to load
                pg["items"] = JSONValue(items);
                page = pg.toString();
                if (gridRows !is null)
                    gridRows.update(items);   // the grid shows what the page does
                pageChanged.emit();
            });
            return;
        }
        if (fMoment.length)
        {
            if (offset == 0)
                items.length = 0;
            if (limit > 0)
                pageLimit = limit;
            JSONValue tp = JSONValue.emptyObject;
            tp["key"] = fMoment;
            tp["offset"] = offset;
            tp["limit"] = pageLimit;
            immutable toff = offset;
            client.request("moments.page", tp, (r, e) {
                if (e.type != JSONType.null_) { report("moments.page", e); return; }
                if (!fMoment.length) return;
                if (toff == 0)
                    items.length = 0;
                total = r["total"].integer;
                immutable first = items.length;
                foreach (it; r["items"].array)
                    items ~= it;
                if (remote)
                    fetchThumbs(first);
                else
                    publishPage();
            });
            return;
        }
        if (fMemory.length)
        {
            if (offset == 0)
                items.length = 0;
            if (limit > 0)
                pageLimit = limit;
            JSONValue mp = JSONValue.emptyObject;
            mp["key"] = fMemory;
            mp["offset"] = offset;
            mp["limit"] = pageLimit;
            immutable moff = offset;
            client.request("memories.page", mp, (r, e) {
                if (e.type != JSONType.null_) { report("memories.page", e); return; }
                if (!fMemory.length) return;
                if (moff == 0)
                    items.length = 0;
                total = r["total"].integer;
                immutable first = items.length;
                foreach (it; r["items"].array)
                    items ~= it;
                if (remote)
                    fetchThumbs(first);
                else
                    publishPage();
            });
            return;
        }
        if (offset == 0 && !refresh)
            items.length = 0;   // (a refresh keeps them until its answer replaces them)
        if (limit > 0)
            pageLimit = limit;
        JSONValue params = JSONValue.emptyObject;
        params["offset"] = offset;
        params["limit"] = pageLimit;
        if (fYear)  params["year"]  = fYear;
        if (fMonth) params["month"] = fMonth;
        if (fDay)   params["day"]   = fDay;
        if (fPerson) params["personId"] = fPerson;
        if (fAlbum)  params["albumId"] = fAlbum;
        if (fRoot)   params["rootId"] = fRoot;
        if (fFavorites) params["favorites"] = true;
        if (kindParam().length) params["kind"] = kindParam();
        if (fText.length) params["q"] = fText;
        if (fPlace.length) { params["place"] = fPlace; if (fCountry.length) params["country"] = fCountry; }
        if (fTag.length && fTagGroup.length) params[fTagGroup] = fTag;
        if (fKeyword.length) params["keyword"] = fKeyword;
        if (refresh && offset == 0)
            params["refresh"] = true;
        immutable off = offset;
        immutable epoch = offset == 0 ? ++pageEpoch : pageEpoch;
        client.request("library.page", params, (r, e) {
            if (epoch != pageEpoch)
                return;   // a newer listing replaced this one
            if (e.type != JSONType.null_)
            {
                // the phone core cut an outdated request short, or a refresh found the computer
                // too slow (the listing on screen stays): neither is a failure to show
                immutable quiet = isSuperseded(e) || (e.type == JSONType.object && "code" in e
                    && e["code"].type == JSONType.string && e["code"].str == "refresh_timeout");
                if (!quiet)
                    report("page", e);
                return;
            }
            if (off != 0 && off != items.length)
                return;   // another answer for this stretch already arrived (a repeated load-more)
            if (off == 0)
                items.length = 0;
            total = r["total"].integer;
            immutable first = items.length;
            foreach (it; r["items"].array)
                items ~= it;
            if (remote)
                fetchThumbs(first);
            else
                publishPage();
        });
    }

    /// The years → months → days tree of the current person/album/root/favourites/kind view.
    @Slot void loadDates()
    {
        JSONValue params = JSONValue.emptyObject;
        if (fPerson) params["personId"] = fPerson;
        if (fAlbum)  params["albumId"] = fAlbum;
        if (fRoot)   params["rootId"] = fRoot;
        if (fFavorites) params["favorites"] = true;
        if (kindParam().length) params["kind"] = kindParam();
        if (fText.length) params["q"] = fText;
        if (fPlace.length) { params["place"] = fPlace; if (fCountry.length) params["country"] = fCountry; }
        if (fTag.length && fTagGroup.length) params[fTagGroup] = fTag;
        if (fKeyword.length) params["keyword"] = fKeyword;
        client.request("library.dates", params, (r, e) {
            if (e.type != JSONType.null_) { report("dates", e); return; }
            dates = r.toString();
            datesChanged.emit();
        });
    }

    /// Phone: rescan the device's photos now (after the editor saved a new file, say).
    @Slot void rescanPhotos()
    {
        client.request("library.rescan", (r, e) { if (e.type == JSONType.null_) loadDates(); });
    }

    @Slot void refresh()
    {
        loadPlaces();
        loadMemories();
        loadMoments();
        loadPresets();
        loadKeywords();
        loadTags();
        loadTagLabels();
        loadDates();
        loadRoots();
        loadAlbums();
        loadPeers();
        loadPeerNames();
        loadPeople();
        loadStats();
        reload(0, pageLimit);
    }

    @Slot void openPhoto(int id)
    {
        if (openId != id)
        {
            photoTags = `{"id":0}`;
            photoTagsChanged.emit();
            loadPhotoTags(id);
        }
        openId = id;
        JSONValue params = ["id": JSONValue(id)];
        client.request("photo.get", params, (r, e) {
            if (id != openId) return;   // closed, or another photo opened meanwhile
            if (e.type != JSONType.null_) { report("photo.get", e); return; }
            JSONValue nb = JSONValue.emptyObject;
            nb["id"] = id;
            if (fYear)  nb["year"]  = fYear;
            if (fMonth) nb["month"] = fMonth;
            if (fDay)   nb["day"]   = fDay;
            if (fPerson) nb["personId"] = fPerson;
            if (fAlbum)  nb["albumId"] = fAlbum;
            if (fRoot)   nb["rootId"] = fRoot;
            if (fFavorites) nb["favorites"] = true;
            if (kindParam().length) nb["kind"] = kindParam();   // the grid's own filter (the default hides screenshots/memes)
            loadFaces(id);
            // A new listing (a refresh after library.changed, say) cuts a neighbours search
            // short on the phone core: ask again. No cap — the new request queues behind the
            // listing that cut this one short, so it repeats only once per real new listing.
            void delegate(JSONValue, JSONValue) onNeighbours;
            onNeighbours = (JSONValue n, JSONValue e2) {
                if (id != openId) return;
                if (isSuperseded(e2))
                {
                    writeln("library: neighbours search cut short by a new listing — asking again");
                    stdout.flush();
                    client.request("photo.neighbours", nb, onNeighbours);
                    return;
                }
                if (e2.type != JSONType.null_)   // e.g. search_limit: shown, without arrows
                {
                    writeln("library: no neighbours for ", id, ": ", e2.toString());
                    stdout.flush();
                }
                JSONValue photo = r;
                photo["prev"] = (e2.type == JSONType.null_ && "prev" in n) ? n["prev"] : JSONValue(null);
                photo["next"] = (e2.type == JSONType.null_ && "next" in n) ? n["next"] : JSONValue(null);
                if (!remote)
                {
                    current = photo.toString();
                    currentChanged.emit();
                    return;
                }
                // show the thumbnail at once, the real bytes when they arrive
                if (auto t = cast(long) id in thumbCache)
                    photo["fileUrl"] = *t;
                current = photo.toString();
                currentChanged.emit();
                JSONValue fp = JSONValue.emptyObject;
                fp["id"] = id;
                fp["maxEdge"] = 2048;
                client.request("photo.file", fp, (f, e3) {
                    if (e3.type != JSONType.null_ || current.length == 0 || id != openId) return;
                    auto cur = parseJSON(current);
                    if (cur["id"].integer != id) return; // moved on already
                    cur["fileUrl"] = "data:" ~ f["mime"].str ~ ";base64," ~ f["base64"].str;
                    current = cur.toString();
                    currentChanged.emit();
                });
            };
            client.request("photo.neighbours", nb, onNeighbours);
        });
    }

    @Slot void closePhoto()
    {
        openId = 0;
        current = "";
        currentChanged.emit();
        faces = `{"photoId":0,"faces":[]}`;
        facesChanged.emit();
    }

    // ---- people ----------------------------------------------------------------

    @Slot void loadPeople()
    {
        client.request("people.list", (r, e) {
            if (e.type != JSONType.null_) return;
            people = r.toString();
            peopleChanged.emit();
        });
    }

    @Slot void renamePerson(int id, string name)
    {
        JSONValue params = ["id": JSONValue(id), "name": JSONValue(name.strip())];
        client.request("people.rename", params, (r, e) {
            if (e.type != JSONType.null_) { report("rename", e); return; }
            loadPeople();
            if (name.strip().length)
                suggestMerge(id);
        });
    }

    /// Asks whether `personId` looks like someone already known; publishes `suggestion`.
    private void suggestMerge(long personId)
    {
        JSONValue params = ["id": JSONValue(personId)];
        client.request("people.similar", params, (r, e) {
            if (e.type != JSONType.null_) return;
            if ("candidates" in r && r["candidates"].array.length)
            {
                suggestion = r.toString();
                suggestionChanged.emit();
            }
        });
    }

    @Slot void dismissSuggestion()
    {
        suggestion = "{}";
        suggestionChanged.emit();
    }

    @Slot void mergePeople(int id, int into)
    {
        JSONValue params = ["id": JSONValue(id), "into": JSONValue(into)];
        client.request("people.merge", params, (r, e) {
            if (e.type != JSONType.null_) { report("merge", e); return; }
            if (fPerson == id)
                setPersonFilter(into);
            loadPeople();
            reload(0, pageLimit);
        });
    }

    /// Names a face: an existing person (personId > 0), a person by name
    /// (created when new), or nobody (both empty).
    @Slot void setFacePerson(int faceId, int personId, string name)
    {
        JSONValue params = JSONValue.emptyObject;
        params["faceId"] = faceId;
        if (personId > 0) params["personId"] = personId;
        if (name.strip().length) params["name"] = name.strip();
        client.request("face.setPerson", params, (r, e) {
            if (e.type != JSONType.null_) { report("setFacePerson", e); return; }
            if ("personId" in r && r["personId"].type == JSONType.integer && name.strip().length)
                suggestMerge(r["personId"].integer);
            immutable followed = "followed" in r ? r["followed"].integer : 0;
            if (followed)
                setStatus(true, indexing, followed.to!string ~ " other face" ~ (followed == 1 ? "" : "s")
                    ~ " that looked like this one moved too");
            loadPeople();
            if (openId)
                loadFaces(openId);
            if (fPerson)
                reload(0, pageLimit);
        });
    }

    /// "Not a face".
    @Slot void deleteFace(int faceId)
    {
        JSONValue params = ["faceId": JSONValue(faceId)];
        client.request("face.delete", params, (r, e) {
            if (e.type != JSONType.null_) { report("face.delete", e); return; }
            loadPeople();
            if (openId)
                loadFaces(openId);
        });
    }

    /// "Not a person": drops an automatic group and its detections.
    @Slot void deletePerson(int personId)
    {
        JSONValue params = ["id": JSONValue(personId)];
        client.request("people.delete", params, (r, e) {
            if (e.type != JSONType.null_) { report("people.delete", e); return; }
            if (fPerson == personId)
                showAll();
            loadPeople();
        });
    }

    @Slot void scanFaces()
    {
        client.request("faces.scan", (r, e) { if (e.type != JSONType.null_) report("faces.scan", e); });
    }

    private void loadFaces(long photoId)
    {
        JSONValue params = ["id": JSONValue(photoId)];
        client.request("photo.faces", params, (r, e) {
            if (e.type != JSONType.null_ || openId != photoId) return;
            faces = r.toString();
            facesChanged.emit();
        });
    }

    @Slot void next() { step("next"); }
    @Slot void prev() { step("prev"); }

    @Slot void connectPeer(string multiaddr)
    {
        JSONValue params = ["multiaddr": multiaddr.strip()];
        client.request("p2p.connect", params, (r, e) {
            if (e.type != JSONType.null_) { report("p2p.connect", e); return; }
            loadPeers();
        });
    }

    /// Give a peer a nickname (empty name clears it), then refresh the panel.
    @Slot void setPeerName(string peerId, string name)
    {
        JSONValue params = ["peerId": peerId, "name": name];
        client.request("peer.setName", params, (r, e) {
            if (e.type != JSONType.null_) { report("peer.setName", e); return; }
            loadPeerNames();
        });
    }

    /// The albums again (a picker about to show them).
    @Slot void refreshAlbums()
    {
        loadAlbums();
    }

    @Slot void createAlbum(string name, string photoIdsJson)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["name"] = name;
        params["photoIds"] = ids;
        client.request("album.create", params, (r, e) {
            if (e.type != JSONType.null_) { report("album.create", e); tell(errorText(e)); return; }
            loadAlbums();
            tell(albumOutcome(r, "Album “" ~ name ~ "” created"));
        });
    }

    @Slot void publishAlbum(int id)
    {
        JSONValue params = ["id": JSONValue(id)];
        client.request("album.publish", params, (r, e) {
            if (e.type != JSONType.null_) { report("album.publish", e); return; }
            loadAlbums();
        });
    }

    @Slot void renameAlbum(int id, string name)
    {
        JSONValue params = JSONValue.emptyObject;
        params["id"] = id;
        params["name"] = name;
        client.request("album.rename", params, (r, e) {
            if (e.type != JSONType.null_) { report("album.rename", e); return; }
            loadAlbums();
        });
    }

    @Slot void deleteAlbum(int id)
    {
        client.request("album.delete", JSONValue(["id": JSONValue(id)]), (r, e) {
            if (e.type != JSONType.null_) { report("album.delete", e); return; }
            loadAlbums();
        });
    }

    @Slot void removeFromAlbum(int albumId, string photoIdsJson)
    {
        JSONValue ids;
        try
            ids = parseJSON(photoIdsJson);
        catch (JSONException)
            ids = JSONValue.emptyArray;
        JSONValue params = JSONValue.emptyObject;
        params["id"] = albumId;
        params["photoIds"] = ids;
        client.request("album.removePhotos", params, (r, e) {
            if (e.type != JSONType.null_) { report("album.removePhotos", e); return; }
            loadAlbums();
        });
    }

    /// Fetch an album another wagon published (a "share code" the peer sent us splits into
    /// their peerId + the manifest hash): pulls the manifest + thumbnails, creating a local
    /// album whose photos live on the peer.
    @Slot void fetchSharedAlbum(string peerId, string manifest)
    {
        JSONValue params = JSONValue.emptyObject;
        params["peerId"] = peerId;
        params["manifest"] = manifest;
        client.request("p2p.fetchAlbum", params, (r, e) {
            if (e.type != JSONType.null_) { report("p2p.fetchAlbum", e); return; }
            loadAlbums();
        });
    }

    @Slot void quit()
    {
        QCoreApplication.quit();
    }

    /// Desktop: open (or close) the door for a phone and refresh the QR payload.
    @Slot void setPairing(bool on)
    {
        JSONValue params = ["enable": JSONValue(on)];
        client.request("phone.pairing", params, (r, e) {
            if (e.type != JSONType.null_) { report("pairing", e); return; }
            pairing = r.toString();
            pairingChanged.emit();
        });
    }

    /// Desktop: the paired phones, for the device list.
    @Slot void loadDevices()
    {
        client.request("devices.list", (r, e) {
            if (e.type != JSONType.null_) { report("devices", e); return; }
            devices = r.toString();
            devicesChanged.emit();
        });
    }

    private void deviceAction(string method, string peerId, JSONValue extra = JSONValue.emptyObject)
    {
        JSONValue params = extra.type == JSONType.object ? extra : JSONValue.emptyObject;
        params["peerId"] = peerId;
        client.request(method, params, (r, e) {
            if (e.type != JSONType.null_) { report(method, e); return; }
            loadDevices();
        });
    }

    @Slot void renameDevice(string peerId, string name)
    {
        JSONValue extra = ["name": JSONValue(name)];
        deviceAction("devices.rename", peerId, extra);
    }

    /// Desktop: the operator typed the code the knocking phone shows.
    /// USB: the user said yes in the "new device connected" dialog — pull its photos.
    @Slot void confirmDeviceSync(string serial)
    {
        deviceConnected = "{}";
        deviceConnectedChanged.emit();
        JSONValue params = ["serial": JSONValue(serial)];
        client.request("usb.sync", params, (r, e) {
            if (e.type != JSONType.null_) { report("usb.sync", e); return; }
        });
    }

    /// USB: "Not now" — dismiss the dialog without importing.
    @Slot void dismissDevice(string serial)
    {
        cast(void) serial;
        deviceConnected = "{}";
        deviceConnectedChanged.emit();
    }

    @Slot void confirmDevice(string peerId, string code)
    {
        JSONValue params = ["peerId": JSONValue(peerId), "code": JSONValue(code)];
        client.request("devices.confirm", params, (r, e) {
            if (e.type != JSONType.null_) { report("devices.confirm", e); return; }
            // clear the prompt if it was accepted; on a wrong code leave it up to retry
            if (r.type == JSONType.object && "ok" in r && r["ok"].type == JSONType.true_)
            {
                pairingRequest = "{}";
                pairingRequestChanged.emit();
            }
            loadDevices();
        });
    }

    /// Desktop: turn away a knocking phone without pairing it.
    @Slot void ignorePairing(string peerId)
    {
        JSONValue params = ["peerId": JSONValue(peerId), "code": JSONValue("")];   // never matches a 4-digit code
        client.request("devices.confirm", params, (r, e) {});
        pairingRequest = "{}";
        pairingRequestChanged.emit();
    }

    @Slot void pauseDevice(string peerId) { deviceAction("devices.pause", peerId); }
    @Slot void resumeDevice(string peerId) { deviceAction("devices.resume", peerId); }
    @Slot void revokeDevice(string peerId) { deviceAction("devices.revoke", peerId); }
    @Slot void forgetDevice(string peerId) { deviceAction("devices.forget", peerId); }

    /// Phone: push one photo to the computer's library.
    @Slot void sendToComputer(int id)
    {
        JSONValue params = ["id": JSONValue(id)];
        setStatus(true, indexing, "sending…");
        client.request("photo.upload", params, (r, e) {
            if (e.type != JSONType.null_) { report("send", e); return; }
            setStatus(true, indexing, "sent to the computer");
            if (current.length && parseJSON(current)["id"].integer == id)
                openPhoto(id); // refresh the "sent" flag in the viewer
        });
    }

    /// Phone: hand a photo to the OS share sheet (WhatsApp, e-mail, …). The bridge fetches
    /// a real local file (the phone's own original, or the computer's fetched first) and
    /// calls Android's ACTION_SEND. A no-op on the desktop bridge (no such request).
    @Slot void sharePhoto(int id)
    {
        client.request("photo.share", JSONValue(["id": JSONValue(id)]), (r, e) {
            if (e.type != JSONType.null_) report("share", e);
        });
    }

    /// The visible part of a zoomed photo at the original's resolution.
    @Slot void loadRegion(int id, double x, double y, double w, double h, int px)
    {
        JSONValue params = JSONValue.emptyObject;
        params["id"] = id; params["x"] = x; params["y"] = y; params["w"] = w; params["h"] = h; params["maxEdge"] = px;
        client.request("photo.region", params, (r, e) {
            if (e.type != JSONType.null_) return;
            if (openId != id) return;   // moved on
            JSONValue out_ = JSONValue.emptyObject;
            out_["id"] = id; out_["x"] = x; out_["y"] = y; out_["w"] = w; out_["h"] = h;
            // the phone's core decodes it to a local file (raw); the desktop daemon answers inline
            out_["url"] = "fileUrl" in r ? r["fileUrl"].str : "data:" ~ r["mime"].str ~ ";base64," ~ r["base64"].str;
            region = out_.toString();
            regionChanged.emit();
        });
    }

    /// The phone's viewer zoomed in: the original as a local file (answers land in `original`).
    @Slot void loadOriginal(int id)
    {
        client.request("photo.download", JSONValue(["id": JSONValue(id)]), (r, e) {
            if (e.type != JSONType.null_) { report("photo.download", e); return; }
            if (openId != id || r.type != JSONType.object || "fileUrl" !in r) return;   // moved on
            original = JSONValue(["id": JSONValue(id), "url": r["fileUrl"]]).toString();
            originalChanged.emit();
        });
    }

    /// Who a face most likely is, for the naming popup (answers land in `candidates`).
    @Slot void loadCandidates(int faceId)
    {
        JSONValue params = ["id": JSONValue(faceId)];
        if (remote) params["inline"] = true;
        client.request("face.candidates", params, (r, e) {
            if (e.type != JSONType.null_) return;
            candidates = r.toString();
            candidatesChanged.emit();
        });
    }

    /// This face is the person's portrait from now on.
    @Slot void setPersonCover(int personId, int faceId)
    {
        JSONValue params = ["id": JSONValue(personId), "faceId": JSONValue(faceId)];
        client.request("people.setCover", params, (r, e) {
            if (e.type != JSONType.null_) { report("setCover", e); return; }
            loadPeople();
        });
    }

    /// The person leaves People; the detections stay, unnamed.
    @Slot void removePerson(int personId)
    {
        JSONValue params = ["id": JSONValue(personId)];
        client.request("people.remove", params, (r, e) {
            if (e.type != JSONType.null_) { report("removePerson", e); return; }
            if (fPerson == personId) showAll();
            loadPeople();
        });
    }

    /// The same kind for many photos at once.
    @Slot void setKinds(string idsJson, string kind)
    {
        foreach (v; parseJSON(idsJson).array)
            setKind(cast(int) v.integer, kind);
    }

    /// The selection leaves the library: files to the trash, or gone for good.
    @Slot void deletePhotos(string idsJson, bool permanent)
    {
        auto ids = parseJSON(idsJson);
        JSONValue params = ["ids": ids, "permanent": JSONValue(permanent)];
        bool currentGone;
        if (current.length)
        {
            immutable cid = parseJSON(current)["id"].integer;
            foreach (v; ids.array) if (v.integer == cid) currentGone = true;
        }
        client.request("photo.delete", params, (r, e) {
            if (e.type != JSONType.null_) { report("delete", e); return; }
            immutable n = r["deleted"].integer;
            immutable failed = r["failed"].array.length;
            setStatus(true, indexing, (permanent ? "deleted " : "moved to the trash: ") ~ n.to!string ~ (n == 1 ? " photo" : " photos")
                ~ (failed ? ", " ~ failed.to!string ~ " failed" : ""));
            if (currentGone) closePhoto();
            reload(0, cast(int) (items.length > pageLimit ? (items.length > 2000 ? 2000 : items.length) : pageLimit));
            loadDates(); loadStats(); loadPeople();
        });
    }

    /// Plain text on the clipboard (paths, a name).
    @Slot void copyText(string text)
    {
        import qt.quick.qguiapplication : QGuiApplication;
        import qt.quick.qclipboard : QClipboard;
        QGuiApplication.clipboard().setText(text, QClipboard.Mode.Clipboard);
    }

    /// Puts the files on the clipboard: as file URLs for file managers (and the
    /// GNOME "copy" form), and as paths as text.
    @Slot void copyPhotos(string idsJson)
    {
        import photowagon.core.library.calendar : fileUrl;
        import std.array : join;

        string[] paths;
        foreach (v; parseJSON(idsJson).array)
        {
            immutable id = v.integer;
            foreach (ref it; items)
                if (it["id"].integer == id && "path" in it && it["path"].type == JSONType.string)
                    paths ~= it["path"].str;
            if (current.length)
            {
                auto cur = parseJSON(current);
                if (cur["id"].integer == id && "path" in cur && cur["path"].type == JSONType.string && !paths.length)
                    paths ~= cur["path"].str;
            }
        }
        if (!paths.length) return;
        string[] urls;
        foreach (p; paths) urls ~= fileUrl(p);
        // in C++ (csrc/clipboard_qt): the QMimeData belongs to the clipboard alone — a D-side
        // one was also freed by the collector, and the app crashed on the next clipboard event
        version (WithUi)
        {
            import std.string : toStringz;
            if (pw_clipboard_set_files((urls.join("\r\n") ~ "\r\n").toStringz, ("copy\n" ~ urls.join("\n")).toStringz, paths.join("\n").toStringz) != 0)
            {
                report("copy", parseJSON(`{"code":"internal","message":"no clipboard"}`));
                return;
            }
        }
        else
        {
            report("copy", parseJSON(`{"code":"internal","message":"no file clipboard on the phone"}`));
            return;
        }
        setStatus(true, indexing, paths.length == 1 ? "copied 1 photo" : "copied " ~ paths.length.to!string ~ " photos");
    }

    /// Phone: keep the computer up to date by itself (on), or stop (off).
    @Slot void setAutoSync(bool on)
    {
        JSONValue params = ["on": JSONValue(on)];
        client.request("library.autoSync", params, (r, e) {
            if (e.type != JSONType.null_) { report("autoSync", e); return; }
            sync = r.toString();
            syncChanged.emit();
        });
    }

    /// Phone: hold sending (the photo in flight finishes) or go on; remembered until changed.
    @Slot void pauseSync(bool paused)
    {
        client.request("library.pauseSync", JSONValue(["paused": JSONValue(paused)]), (r, e) {
            if (e.type != JSONType.null_) { report("pauseSync", e); return; }
            sync = r.toString();
            syncChanged.emit();
            tell(paused ? "Sending paused" : "Sending resumed");
        });
    }

    /// Phone: data saver — nothing goes to the computer over a metered network (4G).
    @Slot void setDataSaver(bool on)
    {
        client.request("library.dataSaver", JSONValue(["on": JSONValue(on)]), (r, e) {
            if (e.type != JSONType.null_) { report("dataSaver", e); return; }
            sync = r.toString();
            syncChanged.emit();
        });
    }

    /// Phone: push everything not sent yet, one after another (and turn the automatic sync on).
    @Slot void sendAll()
    {
        client.request("library.sendAll", (r, e) {
            if (e.type != JSONType.null_) { report("sendAll", e); return; }
            immutable n = r["queued"].integer;
            setStatus(true, indexing, n ? "sending " ~ n.to!string ~ " photo" ~ (n == 1 ? "" : "s") ~ "…" : "nothing new to send");
        });
    }

    // ---- daemon → D ------------------------------------------------------------

    /// The phone core's full state after a (re)connection (docs/phone-core-service.md): applied
    /// field by field instead of replaying events — a fake index.done would reload everything.
    /// Resets a stale "indexing" spinner when the core comes back idle.
    private void applyCoreState(JSONValue st)
    {
        if (st.type != JSONType.object)
            return;
        if ("computer" in st && st["computer"].type == JSONType.object)
        {
            auto c = st["computer"];
            computerConnected = "connected" in c && c["connected"].type == JSONType.true_;
            computerPaired = computerConnected || ("paired" in c && c["paired"].type == JSONType.true_);
            if ("endpoint" in c && c["endpoint"].type == JSONType.string)
                endpoint = c["endpoint"].str;
            endpointChanged.emit();
        }
        if ("pairingCode" in st)
        {
            pairingCode = st["pairingCode"].type == JSONType.string
                ? JSONValue(["code": st["pairingCode"]]).toString() : "{}";
            pairingCodeChanged.emit();
        }
        if ("sync" in st && st["sync"].type == JSONType.object)
        {
            sync = st["sync"].toString();
            syncChanged.emit();
        }
        if ("indexing" in st && st["indexing"].type == JSONType.object)
        {
            auto ix = st["indexing"];
            if ("active" in ix && ix["active"].type == JSONType.true_)
            {
                indexing = true;
                if ("imported" in ix && "total" in ix)
                    progressText = "indexing " ~ (ix["imported"].integer
                        + ("skipped" in ix ? ix["skipped"].integer : 0)).to!string
                        ~ " / " ~ ix["total"].integer.to!string;
            }
            else if (indexing)
            {
                indexing = false;   // the core is idle: whatever spinner we had is stale
                progressText = "library up to date";
                writeln("library: stale indexing state reset (the core is idle)");
            }
        }
        writeln("library: core state applied (computer ", computerConnected ? "up" : "down",
            ", indexing ", indexing ? "on" : "off", ")");
        stdout.flush();
    }

    private void onLink(bool up)
    {
        if (up)
        {
            client.request("daemon.hello", (r, e) {
                if (e.type == JSONType.null_)
                {
                    hello = r.toString();
                    helloChanged.emit();
                }
            });
            refresh();
            loadDevices();
            // The viewer's photo, re-read: its neighbours come from the listing refresh() just
            // started over, which the core pages through until it finds the photo.
            if (openId)
                openPhoto(cast(int) openId);
        }
        setStatus(up, indexing, up ? (progressText.length ? progressText : "connected") : "daemon unreachable, retrying…");
    }

    private QTimer timelineLater;   // a library.changed inside the 3 s window, deferred to its end

    private void refreshTimeline()
    {
        if (timelineLater !is null)
            timelineLater.stop();
        lastTimelineHns = Clock.currStdTime;
        loadDates();
        loadStats();
        loadMemories();
        loadMoments();
        immutable onScreen = items.length > 0;
        reload(0, cast(int) (items.length > pageLimit ? (items.length > 2000 ? 2000 : items.length) : pageLimit), onScreen);   // keep what was scrolled to
    }

    private void onEvent(string ev, JSONValue data)
    {
        switch (ev)
        {
        case "index.progress":
            indexing = true;
            progressText = "indexing " ~ (data["imported"].integer + data["skipped"].integer).to!string
                ~ " / " ~ data["total"].integer.to!string;
            setStatus(true, true, progressText);
            break;
        case "index.done":
            indexing = false;
            progressText = data["imported"].integer
                ? data["imported"].integer.to!string ~ " new photo" ~ (data["imported"].integer == 1 ? "" : "s")
                : "library up to date";
            setStatus(true, false, progressText);
            loadDates();
            loadRoots();
            reload(0, pageLimit);
            break;
        case "devices.changed":
            loadDevices();
            break;
        case "pairing.code":
            // {code} to show while first-pairing, or {done:true} once the desktop confirmed
            pairingCode = ("done" in data && data["done"].type == JSONType.true_) ? "{}" : data.toString();
            pairingCodeChanged.emit();
            break;
        case "pairing.request":
            // Desktop: a phone is knocking; show the prompt to enter the code it displays
            pairingRequest = data.toString();
            pairingRequestChanged.emit();
            break;
        case "device.connected":
            // USB: a phone was plugged in; offer to import its camera roll
            deviceConnected = data.toString();
            deviceConnectedChanged.emit();
            break;
        case "device.disconnected":
            try
            {
                auto dc = parseJSON(deviceConnected);
                if ("serial" in dc && dc["serial"].str == data["serial"].str)
                {
                    deviceConnected = "{}";
                    deviceConnectedChanged.emit();
                }
            }
            catch (Exception)
            {
            }
            break;
        case "usb.progress":
            setStatus(true, true, "importing from USB: " ~ data["done"].integer.to!string
                ~ " / " ~ data["total"].integer.to!string);
            break;
        case "usb.done":
            if ("error" in data)
                setStatus(true, indexing, "USB import failed: " ~ data["error"].str);
            else
            {
                immutable skipped = data["total"].integer - data["imported"].integer;
                setStatus(true, indexing, data["imported"].integer.to!string ~ " imported from USB"
                    ~ (skipped > 0 ? ", " ~ skipped.to!string ~ " already had" : ""));
            }
            loadRoots();
            loadDates();
            reload(0, pageLimit);
            break;
        case "library.changed":
            // While a scan runs this fires for every batch of files; refreshing the whole
            // timeline (page string + date tree + stats) each time re-published a huge page and
            // reset the grid model every few seconds — "atualizar a biblioteca deixa o app
            // instável". Coalesce to at most one refresh every 3 s — and one inside the window is
            // not dropped but deferred to its end (the phone's "the computer's page came late"
            // arrives ~2.5 s after the refresh it follows: dropping it left those photos out).
            {
                immutable nowHns = Clock.currStdTime;
                immutable waitHns = lastTimelineHns + 30_000_000 - nowHns;   // 3 s, in 100 ns ticks
                if (waitHns <= 0)
                    refreshTimeline();
                else
                {
                    if (timelineLater is null)
                    {
                        timelineLater = new QTimer(cast(cppq.QObject) null);
                        timelineLater.setSingleShot(true);
                        timelineLater.connectTimeout(&refreshTimeline);
                    }
                    if (!timelineLater.isActive())
                    {
                        timelineLater.setInterval(cast(int) (waitHns / 10_000) + 1);
                        timelineLater.start();
                    }
                }
            }
            break;
        case "tags.progress":
            setStatus(true, true, "finding scenes and moods: " ~ data["done"].integer.to!string
                ~ " / " ~ data["total"].integer.to!string);
            break;
        case "tags.done":
            setStatus(true, indexing, data["tagged"].integer.to!string ~ " of " ~ data["photos"].integer.to!string ~ " photos got a scene or mood");
            break;
        case "files.tags":
            setStatus(true, true, "writing tags into files: " ~ data["done"].integer.to!string ~ " / " ~ data["total"].integer.to!string);
            break;
        case "files.tags.done":
            setStatus(true, indexing, "tags written into " ~ data["written"].integer.to!string ~ " files"
                ~ (data["failed"].integer ? ", " ~ data["failed"].integer.to!string ~ " failed" : ""));
            break;
        case "keywords.changed":
            loadKeywords();
            reload(0, cast(int) (items.length > pageLimit ? (items.length > 2000 ? 2000 : items.length) : pageLimit));
            if (openId)
                openPhoto(cast(int) openId);
            break;
        case "tags.changed":
            loadTags();
            loadMemories();
            if (fTag.length)
                reload(0, pageLimit);
            if (openId)
                loadPhotoTags(cast(int) openId);
            break;
        case "places.changed":
            loadPlaces();
            if (fPlace.length)
            {
                reload(0, pageLimit);
                loadDates();
            }
            break;
        case "p2p.peer":
            loadPeers();
            break;
        case "faces.progress":
            setStatus(true, true, "faces: " ~ data["done"].integer.to!string ~ " / " ~ data["total"].integer.to!string
                ~ " photos, " ~ data["faces"].integer.to!string ~ " found");
            break;
        case "faces.done":
            setStatus(true, indexing, data["faces"].integer.to!string ~ " face" ~ (data["faces"].integer == 1 ? "" : "s")
                ~ " in " ~ data["photos"].integer.to!string ~ " photos");
            loadPeople();
            break;
        case "kinds.progress":
            setStatus(true, true, "sorting photos, screenshots and memes: " ~ data["done"].integer.to!string
                ~ " / " ~ data["total"].integer.to!string);
            break;
        case "kinds.done":
            loadStats();
            reload(0, pageLimit);
            break;
        case "people.changed":
            loadPeople();
            if (openId)
                loadFaces(openId);
            if (fPerson)
                reload(0, pageLimit);
            break;
        case "p2p.fetch":
            setStatus(true, indexing, "fetching album " ~ data["done"].integer.to!string
                ~ " / " ~ data["total"].integer.to!string);
            break;
        case "computer.link":
            computerConnected = data["connected"].boolean;
            computerPaired = computerConnected || ("paired" in data && data["paired"].type == JSONType.true_);
            endpoint = data["endpoint"].str;
            endpointChanged.emit();
            break;
        case "upload.progress":
            setStatus(true, indexing, "sending " ~ (data["done"].integer + 1).to!string ~ " / " ~ data["total"].integer.to!string);
            break;
        case "upload.done":
            setStatus(true, indexing, data["sent"].integer.to!string ~ " sent"
                ~ (data["failed"].integer ? ", " ~ data["failed"].integer.to!string ~ " failed" : ""));
            break;
        case "sync.status":
            sync = data.toString();
            syncChanged.emit();
            break;
        case "core.state":
            applyCoreState(data);
            break;
        case "log":
            writeln("daemon: ", data["message"].str);
            stdout.flush();
            break;
        default:
            break;
        }
    }

    // ---- helpers ---------------------------------------------------------------

    /// Remote only: replaces thumbUrl of items[first..$] with data: URLs, then publishes.
    private void fetchThumbs(size_t first)
    {
        JSONValue[] want;
        foreach (ref it; items[first .. $])
        {
            immutable id = it["id"].integer;
            if (auto t = id in thumbCache)
                it["thumbUrl"] = *t;
            else
                want ~= JSONValue(id);
        }
        if (want.length == 0)
        {
            publishPage();
            return;
        }
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = JSONValue(want);
        client.request("library.thumbs", params, (r, e) {
            if (e.type == JSONType.null_ && "thumbs" in r)
            {
                foreach (key, b64; r["thumbs"].object)
                {
                    immutable id = key.to!long;
                    thumbCache[id] = "data:image/jpeg;base64," ~ b64.str;
                }
                foreach (ref it; items)
                    if (auto t = it["id"].integer in thumbCache)
                        it["thumbUrl"] = *t;
            }
            publishPage();
        });
    }

    private void step(string dir)
    {
        if (current.length == 0)
            return;
        auto cur = parseJSON(current);
        auto id = cur[dir];
        if (id.type == JSONType.null_)
            return;
        openPhoto(cast(int) id.integer);
    }

    private void loadRoots()
    {
        client.request("library.roots", (r, e) {
            if (e.type != JSONType.null_) return;
            roots = r.toString();
            rootsChanged.emit();
        });
    }

    private void loadAlbums()
    {
        client.request("album.list", (r, e) {
            if (e.type != JSONType.null_) return;
            albums = r.toString();
            albumsChanged.emit();
        });
    }

    private void loadPeers()
    {
        client.request("p2p.status", (r, e) {
            if (e.type != JSONType.null_) return;
            peers = r.toString();
            peersChanged.emit();
        });
    }

    private void loadPeerNames()
    {
        client.request("peer.names", (r, e) {
            if (e.type != JSONType.null_) return;
            peerNames = ("names" in r) ? r["names"].toString() : `{}`;
            peerNamesChanged.emit();
        });
    }

    // ---- Tools (desktop) ----------------------------------------------------------

    /// Groups the library's near-identical photos (a background job: poll with pollSimilar).
    @Slot void startSimilarScan(double minSimilarity)
    {
        client.request("tools.similar.start", JSONValue(["minSimilarity": JSONValue(minSimilarity)]), (r, e) {
            if (e.type != JSONType.null_) { report("tools", e); return; }
            pollSimilar();
        });
    }

    @Slot void pollSimilar()
    {
        client.request("tools.similar.status", JSONValue.emptyObject, (r, e) {
            if (e.type != JSONType.null_) { report("tools", e); return; }
            toolsSimilar = r.toString();
            toolsSimilarChanged.emit();
        });
    }

    @Slot void loadThumbTool()
    {
        client.request("tools.thumbnails", JSONValue.emptyObject, (r, e) {
            if (e.type != JSONType.null_) { report("tools", e); return; }
            toolsThumbs = r.toString();
            toolsThumbsChanged.emit();
        });
    }

    /// Polled by the viewer (while false) until the video backend is ready.
    @Slot void checkMedia()
    {
        bool r = true;
        version (WithUi)
            r = pw_media_ready() != 0;
        if (r != mediaReady)
        {
            mediaReady = r;
            mediaReadyChanged.emit();
        }
    }

    /// The screenshots ("screenshot") or memes ("meme"), grouped by app or month.
    @Slot void loadJunk(string kind)
    {
        junkKind = kind;
        client.request("tools.junk", JSONValue(["kind": JSONValue(kind)]), (r, e) {
            if (e.type != JSONType.null_) { report("tools", e); return; }
            if (("kind" in r) is null || r["kind"].str != junkKind)
                return;   // an answer for the other kind, asked before a switch
            toolsJunk = r.toString();
            toolsJunkChanged.emit();
        });
    }

    /// Moves these photos (a JSON array of ids) to the trash, then refreshes the tools and
    /// the timeline.
    @Slot void trashPhotos(string idsJson)
    {
        JSONValue ids;
        try
            ids = parseJSON(idsJson);
        catch (Exception)
            return;
        if (ids.type != JSONType.array || ids.array.length == 0)
            return;
        client.request("photo.delete", JSONValue(["ids": ids]), (r, e) {
            if (e.type != JSONType.null_) { report("delete", e); return; }
            pollSimilar();
            loadThumbTool();
            if (junkKind.length)
                loadJunk(junkKind);
            refreshTimeline();
        });
    }

    /// The unidentified face (group or single face) at `offset`, with who it may be.
    @Slot void loadUnidentified(int offset)
    {
        client.request("tools.unidentified", JSONValue(["offset": JSONValue(offset)]), (r, e) {
            if (e.type != JSONType.null_)
            {
                report("tools", e);
                // still an answer: the dialog lets go of its "busy" and asks again
                toolsFace = JSONValue(["offset": JSONValue(offset)]).toString();
                toolsFaceChanged.emit();
                return;
            }
            auto out_ = r;
            out_["offset"] = offset;
            out_["candidates"] = JSONValue.emptyArray;
            void publish()
            {
                toolsFace = out_.toString();
                toolsFaceChanged.emit();
            }
            if (!("item" in r))
                return publish();
            auto item = r["item"];
            // who it may be: the people closest to the item's (best) face — named ones only
            // (people.similar is stricter and often has nothing for a new group)
            JSONValue faceId = item["type"].str == "cluster"
                ? (item["faces"].array.length ? item["faces"].array[0]["faceId"] : JSONValue(0))
                : item["faceId"];
            client.request("face.candidates", JSONValue(["id": faceId]), (c, ce) {
                if (ce.type == JSONType.null_ && "people" in c)
                {
                    JSONValue[] named;
                    foreach (pj; c["people"].array)
                        if ("name" in pj && pj["name"].type == JSONType.string && pj["name"].str.length
                            && !(item["type"].str == "cluster" && "id" in pj && pj["id"] == item["personId"]))
                            named ~= pj;
                    out_["candidates"] = JSONValue(named.length > 6 ? named[0 .. 6] : named);
                }
                publish();
            });
        });
    }

    /// The unidentified group `personId` IS person `intoId` (merged) — or, `intoId` 0, a new
    /// person called `name`.
    /// `excludedJson`: faces of the group the user said are NOT this person — let go first
    /// (they come back as single faces), so a mixed automatic group is not named wholesale.
    @Slot void resolveCluster(int personId, int intoId, string name, int offset, string excludedJson)
    {
        import std.string : strip;

        long[] excluded;
        try
            foreach (v; parseJSON(excludedJson).array)
                excluded ~= v.integer;
        catch (Exception)
        {
        }
        void act()
        {
            auto next = () { loadUnidentified(offset); loadPeople(); };
            if (intoId > 0)
                client.request("people.merge", JSONValue(["id": JSONValue(personId), "into": JSONValue(intoId)]),
                    (r, e) { if (e.type != JSONType.null_) report("merge", e); next(); });
            else if (name.strip.length)
                client.request("people.rename", JSONValue(["id": JSONValue(personId), "name": JSONValue(name.strip)]),
                    (r, e) { if (e.type != JSONType.null_) report("rename", e); next(); });
        }
        // one at a time, then the group's decision
        void detach(size_t i)
        {
            if (i >= excluded.length)
                return act();
            client.request("face.setPerson", JSONValue(["faceId": JSONValue(excluded[i]), "personId": JSONValue(0)]),
                (r, e) { if (e.type != JSONType.null_) report("face", e); detach(i + 1); });
        }
        detach(0);
    }

    /// The automatic group `personId` mixes people up: break it up — its faces stay, each
    /// on its own again (they come back one by one, with their own suggestions).
    @Slot void dissolveCluster(int personId, int offset)
    {
        client.request("people.remove", JSONValue(["id": JSONValue(personId)]), (r, e) {
            if (e.type != JSONType.null_) report("people", e);
            loadUnidentified(offset);
            loadPeople();
        });
    }

    /// The group `personId` is not faces: its detections are deleted.
    @Slot void dismissCluster(int personId, int offset)
    {
        client.request("people.delete", JSONValue(["id": JSONValue(personId)]), (r, e) {
            if (e.type != JSONType.null_) report("delete", e);
            loadUnidentified(offset);
        });
    }

    /// A loose face is person `personId` — or, `personId` 0, a new person called `name`.
    @Slot void resolveFace(int faceId, int personId, string name, int offset)
    {
        import std.string : strip;

        JSONValue p = ["faceId": JSONValue(faceId)];
        if (personId > 0)
            p["personId"] = personId;
        else if (name.strip.length)
            p["name"] = name.strip;
        else
            return;
        client.request("face.setPerson", p, (r, e) {
            if (e.type != JSONType.null_) report("face", e);
            loadUnidentified(offset);
            loadPeople();
        });
    }

    /// A loose "face" that is not one: deleted.
    @Slot void dismissFace(int faceId, int offset)
    {
        client.request("face.delete", JSONValue(["faceId": JSONValue(faceId)]), (r, e) {
            if (e.type != JSONType.null_) report("face", e);
            loadUnidentified(offset);
        });
    }

    /// The grid's column count changed (a pinch, a rotation): re-chunk; `anchorPid` is the
    /// photo to keep in view — its new row lands in `anchorRow`.
    @Slot void setGridColumns(int cols, int anchorPid)
    {
        if (gridRows is null)
            return;
        gridRows.setCols(cols);
        if (anchorPid > 0)
        {
            anchorRow = gridRows.rowOf(anchorPid);
            anchorRowChanged.emit();
        }
    }

    private void publishPage()
    {
        if (gridRows !is null)
            gridRows.update(items);
        if (!indexing)
            setStatus(client.connected(), false, total.to!string ~ " photo" ~ (total == 1 ? "" : "s")
                ~ (progressText.length ? " · " ~ progressText : ""));
        JSONValue p = JSONValue.emptyObject;
        p["total"] = total;
        p["offset"] = cast(long) items.length;
        p["items"] = JSONValue(items);
        page = p.toString();
        pageChanged.emit();
    }

    private void setStatus(bool connected, bool busy, string text)
    {
        JSONValue s = JSONValue.emptyObject;
        s["connected"] = connected;
        s["indexing"] = busy;
        s["text"] = text;
        status = s.toString();
        statusChanged.emit();
    }

    private static bool isSuperseded(JSONValue err)
    {
        if (err.type != JSONType.object || !("code" in err) || err["code"].type != JSONType.string)
            return false;
        return err["code"].str == "superseded" || err["code"].str == "session_superseded";
    }

    private void report(string what, JSONValue err)
    {
        immutable msg = err.type == JSONType.object && "message" in err ? err["message"].str : err.toString();
        writeln("daemon: ", what, " failed: ", msg);
        stdout.flush();
        setStatus(client.connected(), indexing, what ~ ": " ~ msg);
    }
}

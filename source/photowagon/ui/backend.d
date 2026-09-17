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

import std.json;
import std.stdio : writeln, stdout;
import std.string : startsWith, strip;
import std.conv : to;
import std.datetime.systime : Clock;

import photowagon.ui.transport : Bridge;

version (WithUi)
{
	/// csrc/clipboard_qt.h: the QMimeData is created in C++ so the clipboard is its only owner.
	/// Desktop only: the phone client (no WithUi) has no file clipboard.
	private extern (C) int pw_clipboard_set_files(const char* uris, const char* gnome, const char* text);
}

@QObject class Library
{
    Signal!() pageChanged;
    Signal!() placesChanged;
    Signal!() tagsChanged;
    Signal!() keywordsChanged;
    Signal!() presetsChanged;
    Signal!() previewChanged;
    Signal!() presetPreviewsChanged;
    Signal!() tagLabelsChanged;
    Signal!() photoTagsChanged;
    Signal!() placeSuggestionsChanged;
    Signal!() datesChanged;
    Signal!() rootsChanged;
    Signal!() albumsChanged;
    Signal!() peersChanged;
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
    Signal!() uiStateChanged;

    /// {"total":N,"offset":o,"items":[Photo…]} — accumulated across loadPage calls.
    @Property("pageChanged")    string page   = `{"total":0,"offset":0,"items":[]}`;
    /// {"years":[{year,count,months:[{month,count,days:[{day,count}]}]}]}
    @Property("datesChanged")   string dates  = `{"years":[]}`;
    @Property("rootsChanged")   string roots  = `{"roots":[]}`;
    @Property("albumsChanged")  string albums = `{"albums":[]}`;
    @Property("peersChanged")   string peers  = `{"peerId":"","addrs":[],"peers":[]}`;
    /// {"connected":bool,"indexing":bool,"text":"…"}
    @Property("statusChanged")  string status = `{"connected":false,"indexing":false,"text":"starting…"}`;
    @Property("helloChanged")   string hello  = `{}`;
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
    private long lastTimelineHns;   // Clock.currStdTime of the last library.changed refresh (coalescing)
    /// Screenshots and memes stay out of the library timeline (they have their own
    /// views under Media Types); an album, a search or an explicit kind shows everything.
    private bool onlyPhotos = true;

    private string kindParam()
    {
        if (fKind.length) return fKind;
        if (onlyPhotos && !fAlbum && !fText.length && !fPlace.length && !fTag.length && !fKeyword.length) return "photo";
        return null;
    }
    private long openId; // photo being opened/shown; faces answers for others are dropped
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

    /// A year, a month or a day (0 = any). Keeps a person/album/root filter.
    @Slot void filterDate(int year, int month, int day)
    {
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

    /// Photos whose file name or folder contains `q` ("" = everything).
    @Slot void filterSearch(string q)
    {
        import std.string : strip;
        clearFilters();
        fText = q.strip();
        publishFilter();
        reload(0, pageLimit);
        loadDates();
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

    /// Throw photo `id` onto the screen at host:port.
    @Slot void castTo(string host, int port, int id)
    {
        JSONValue params = ["host": JSONValue(host), "port": JSONValue(port), "id": JSONValue(id)];
        client.request("cast.photo", params, (r, e) {
            if (e.type != JSONType.null_) { report("cast.photo", e); return; }
        });
    }

    /// Start a looping slideshow of the library on host:port, one photo every 5 s.
    @Slot void castSlideshow(string host, int port)
    {
        JSONValue params = ["host": JSONValue(host), "port": JSONValue(port), "intervalMs": JSONValue(5000)];
        client.request("cast.slideshow", params, (r, e) {
            if (e.type != JSONType.null_) { report("cast.slideshow", e); return; }
        });
    }

    @Slot void castStop()
    {
        client.request("cast.stop", (r, e) { cast(void) r; cast(void) e; });
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
            if (e.type != JSONType.null_) { report("album.addPhotos", e); return; }
            loadAlbums();
            setStatus(true, indexing, "added to the album");
        });
    }

    private void reload(int offset, int limit)
    {
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
                pg["offset"] = 0;
                pg["items"] = JSONValue(items);
                page = pg.toString();
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
        if (offset == 0)
            items.length = 0;
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
        immutable off = offset;
        client.request("library.page", params, (r, e) {
            if (e.type != JSONType.null_) { report("page", e); return; }
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
            if (fKind.length) nb["kind"] = fKind;
            loadFaces(id);
            client.request("photo.neighbours", nb, (n, e2) {
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
                    if (e3.type != JSONType.null_ || current.length == 0) return;
                    auto cur = parseJSON(current);
                    if (cur["id"].integer != id) return; // moved on already
                    cur["fileUrl"] = "data:" ~ f["mime"].str ~ ";base64," ~ f["base64"].str;
                    current = cur.toString();
                    currentChanged.emit();
                });
            });
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
            if (e.type != JSONType.null_) { report("album.create", e); return; }
            loadAlbums();
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
            out_["url"] = "data:" ~ r["mime"].str ~ ";base64," ~ r["base64"].str;
            region = out_.toString();
            regionChanged.emit();
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
        }
        setStatus(up, indexing, up ? (progressText.length ? progressText : "connected") : "daemon unreachable, retrying…");
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
            // instável". Coalesce to at most one refresh every 3 s; index.done / upload.done do a
            // final, unthrottled reload so nothing is left stale at the end.
            {
                immutable nowHns = Clock.currStdTime;
                if (nowHns - lastTimelineHns >= 30_000_000)   // 3 s, in 100 ns ticks
                {
                    lastTimelineHns = nowHns;
                    loadDates();
                    loadStats();
                    loadMemories();
                    loadMoments();
                    reload(0, cast(int) (items.length > pageLimit ? (items.length > 2000 ? 2000 : items.length) : pageLimit));   // keep what was scrolled to
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

    private void publishPage()
    {
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

    private void report(string what, JSONValue err)
    {
        immutable msg = err.type == JSONType.object && "message" in err ? err["message"].str : err.toString();
        writeln("daemon: ", what, " failed: ", msg);
        stdout.flush();
        setStatus(client.connected(), indexing, what ~ ": " ~ msg);
    }
}

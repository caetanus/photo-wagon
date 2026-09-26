// PW_TEST_PAGING=full|deadline|deadline2|slow — a scripted check of LocalBridge's paging (stage 3 of
// docs/phone-core-service.md), run by the desktop build of the phone app against a real
// computer link. Pair it with PW_TEST_PAGE_DELAY=<ms> so the computer's replies arrive late
// and out of order. Logs "paging-test: PASS" or "paging-test: FAIL <why>" and exits.
module photowagon.mobile.pagingtest;

import photowagon.mobile.localbridge : LocalBridge;
import photowagon.mobile.plog : plog;

import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import std.conv : to;
import std.json;

final class PagingTest
{
    private LocalBridge core;
    private string mode;
    private bool started;
    private string[] failures;
    private QTimer wait;

    this(LocalBridge core, string mode)
    {
        this.core = core;
        this.mode = mode;
    }

    private bool linkUp, indexed;

    /// Called on every computer.link event.
    void onLink(bool up)
    {
        linkUp = up;
        go();
    }

    /// Called on index.done: the phone's own photos are all in (a scan still running would
    /// shift the local offsets under the walk — the UI reloads on library.changed for that).
    void onIndexed()
    {
        indexed = true;
        if (mode == "refresh" && rescanPending)
        {
            rescanPending = false;
            refreshStep2();
            return;
        }
        go();
    }

    private void go()
    {
        if (!linkUp || !indexed || started)
            return;
        started = true;
        plog("paging-test: start (", mode, ")");
        if (mode == "deadline")
            deadline();
        else if (mode == "deadline2")
            laterDeadline();
        else if (mode == "slow")
            slowComputer();
        else if (mode == "refresh")
            refreshTest();
        else
            overlap();
    }

    private void check(bool ok, string what)
    {
        if (!ok)
        {
            failures ~= what;
            plog("paging-test: check failed: ", what);
        }
    }

    private static JSONValue pg(long offset, long limit)
    {
        return JSONValue(["offset": JSONValue(offset), "limit": JSONValue(limit)]);
    }

    private static bool isRemote(JSONValue it)
    {
        return "remote" in it && it["remote"].type == JSONType.true_;
    }

    private static bool isErr(JSONValue e, string code)
    {
        return e.type == JSONType.object && "code" in e && e["code"].str == code;
    }

    // 1. A listing, its load-more, then a second listing — all before any reply. The first
    //    two must fail as superseded (at once, not hang); the second listing must be whole.
    private void overlap()
    {
        int pending = 4;
        JSONValue[] b1, b2;
        void next()
        {
            if (--pending == 0)
            {
                check(b1.length == 60, "listing B page 1 has 60 items (got " ~ b1.length.to!string ~ ")");
                walk();
            }
        }
        core.request("library.page", pg(0, 60), (r, e) {
            check(isErr(e, "superseded"), "listing A superseded (got " ~ e.toString() ~ ")");
            next();
        });
        core.request("library.page", pg(60, 60), (r, e) {
            check(isErr(e, "superseded"), "A's load-more superseded (got " ~ e.toString() ~ ")");
            next();
        });
        core.request("library.page", pg(0, 60), (r, e) {
            check(e.type == JSONType.null_, "listing B answered (" ~ e.toString() ~ ")");
            if (e.type == JSONType.null_)
            {
                b1 = r["items"].array;
                check(r["offset"].integer == 60, "B page 1 offset 60");
            }
            next();
        });
        // queued behind B's first page: must run after it, at offset 60
        core.request("library.page", pg(60, 60), (r, e) {
            check(e.type == JSONType.null_, "B's load-more answered (" ~ e.toString() ~ ")");
            if (e.type == JSONType.null_)
                b2 = r["items"].array;
            check(b2.length > 0 && b1.length && b2[0]["id"] != b1[0]["id"], "B's load-more continues after page 1");
            next();
        });
    }

    // 2. Walk the whole listing: unique ids, newest first, the count the core reports.
    private JSONValue[] all;
    private long reportedTotal;

    private void walk()
    {
        core.request("library.page", pg(0, 45), (r, e) { walkStep(r, e); });
    }

    private void walkStep(JSONValue r, JSONValue e)
    {
        check(e.type == JSONType.null_, "walk page answered (" ~ e.toString() ~ ")");
        if (e.type != JSONType.null_)
            return finish();
        auto items = r["items"].array;
        all ~= items;
        reportedTotal = r["total"].integer;
        check(r["offset"].integer == all.length, "walk offset " ~ r["offset"].integer.to!string ~ " == " ~ all.length.to!string);
        if (items.length == 0)
        {
            bool[long] seen;
            bool ordered = true;
            foreach (i, it; all)
            {
                seen[it["id"].integer] = true;
                if (i && it["takenTs"].integer > all[i - 1]["takenTs"].integer)
                    ordered = false;
            }
            check(seen.length == all.length, "walk: no duplicates (" ~ seen.length.to!string ~ " unique of " ~ all.length.to!string ~ ")");
            check(ordered, "walk: newest first");
            check(reportedTotal == all.length, "walk: total " ~ reportedTotal.to!string ~ " == walked " ~ all.length.to!string);
            long remotes;
            foreach (it; all)
                if (isRemote(it))
                    remotes++;
            check(remotes > 0 && remotes < all.length, "walk: merges phone and computer photos (" ~ remotes.to!string ~ " remote)");
            plog("paging-test: walked ", all.length, " (", remotes, " from the computer)");
            return replay();
        }
        core.request("library.page", pg(all.length, 45), (r2, e2) { walkStep(r2, e2); });
    }

    // 3. A stretch already served comes back identical (a UI rebuilding its list).
    private void replay()
    {
        core.request("library.page", pg(45, 45), (r, e) {
            check(e.type == JSONType.null_, "replay answered");
            if (e.type == JSONType.null_)
            {
                auto items = r["items"].array;
                bool same = items.length == 45;
                foreach (i, it; items)
                    if (same && it["id"] != all[45 + i]["id"])
                        same = false;
                check(same, "replay of 45..90 returns the same photos");
                check(r["offset"].integer == 90, "replay offset 90");
            }
            deepNeighbours();
        });
    }

    // 4. A fresh listing (first page only), then the neighbours of the LAST photo: the core
    //    must page through on its own and find it.
    private void deepNeighbours()
    {
        core.request("library.page", pg(0, 30), (r, e) {
            check(e.type == JSONType.null_, "fresh listing answered");
            if (all.length < 231)   // the walk came up short (already failed): nothing to probe
            {
                check(false, "the walk has the 231 photos the neighbour checks need");
                finish();
                return;
            }
            immutable last = all[$ - 1]["id"].integer;
            immutable before = all[$ - 2]["id"].integer;
            // 30 served + one 200-photo search page = 230: photo 229 ends up LAST served, and
            // its successor is still to come
            core.request("photo.neighbours", JSONValue(["id": all[229]["id"]]), (b, eb) {
                check(eb.type == JSONType.null_ && b["prev"] == all[228]["id"] && b["next"] == all[230]["id"],
                    "neighbours at a page boundary: prev 228 and next 230 (" ~ b.toString() ~ ")");
            });
            core.request("photo.neighbours", JSONValue(["id": JSONValue(last)]), (n, e2) {
                check(e2.type == JSONType.null_, "neighbours answered (" ~ e2.toString() ~ ")");
                if (e2.type == JSONType.null_)
                {
                    check(n["prev"].type == JSONType.integer && n["prev"].integer == before,
                        "deep neighbours: prev of the last photo is the one before it (" ~ n.toString() ~ ")");
                    check(n["next"].type == JSONType.null_, "deep neighbours: the last photo has no next");
                }
                // the UI's own load-more after that: continues at 30, replayed from what the
                // neighbours search already served
                core.request("library.page", pg(30, 30), (r3, e3) {
                    check(e3.type == JSONType.null_ && r3["items"].array.length == 30
                        && r3["items"].array[0]["id"] == all[30]["id"], "load-more after the neighbours search continues at 30");
                    session();
                });
            });
        });
    }

    // 5. A new session while a page is pending: the page fails as session_superseded.
    private void session()
    {
        bool answered;
        core.request("library.page", pg(0, 60), (r, e) {
            answered = true;
            check(isErr(e, "session_superseded") || e.type == JSONType.null_,
                "page pending at a new session: superseded (or already done)");
            if (e.type == JSONType.null_)
                plog("paging-test: note: the page finished before the session change");
        });
        core.beginSession();
        check(answered, "the pending page was answered by the session change, not left hanging");
        core.request("library.page", pg(0, 60), (r, e) {
            check(e.type == JSONType.null_ && r["items"].array.length == 60, "the new session's listing works");
            finish();
        });
    }

    // PW_TEST_PAGE_DELAY beyond the first page's 2.5 s wait: the page is answered from the
    // phone's own photos, and the late computer reply changes nothing in THIS listing (it
    // asks the UI to refresh, which starts a new one).
    private void deadline()
    {
        import core.time : MonoTime, seconds;

        immutable t0 = MonoTime.currTime;
        core.request("library.page", pg(0, 60), (r, e) {
            immutable took = MonoTime.currTime - t0;
            check(e.type == JSONType.null_, "deadline page answered (" ~ e.toString() ~ ")");
            // the FIRST page waits 2.5 s for the computer, not 20 (localbridge firstPageWaitMs)
            check(took >= 2.seconds && took < 5.seconds, "answered at the first-page deadline (" ~ took.toString() ~ ")");
            long remotes;
            foreach (it; r["items"].array)
                if (isRemote(it))
                    remotes++;
            check(remotes == 0 && r["items"].array.length > 0, "deadline page: phone photos only");
            plog("paging-test: deadline page after ", took, ", ", r["items"].array.length, " items");
            // the late computer reply lands meanwhile (the delay is past the deadline); it must
            // not add to this listing: the next page is still the phone's alone
            wait = new QTimer(cast(cppq.QObject) null);
            wait.setSingleShot(true);
            wait.setInterval(10_000);
            wait.connectTimeout({
                core.request("library.page", pg(60, 60), (r2, e2) {
                    check(e2.type == JSONType.null_, "after the late reply: load-more answered");
                    foreach (it; r2["items"].array)
                        if (isRemote(it))
                        {
                            check(false, "after the late reply: no computer photos in the listing");
                            break;
                        }
                    finish();
                });
            });
            wait.start();
        });
    }

    // PW_TEST_PAGE_DELAY=4000 (fixed): a computer slower than the first page's 2.5 s but well
    // inside the 20 s deadline. The first listing goes without it; once its late page is in,
    // the NEXT first page waits for it and has the computer's photos (it is not cut off at
    // 2.5 s every time, which would leave them out for good).
    private void slowComputer()
    {
        core.request("library.page", pg(0, 60), (r, e) {
            check(e.type == JSONType.null_ && remotesIn(r) == 0, "slow computer: the first listing is the phone's alone");
            wait = new QTimer(cast(cppq.QObject) null);
            wait.setSingleShot(true);
            wait.setInterval(3_000);   // the late page (4 s) lands meanwhile
            wait.connectTimeout({
                core.request("library.page", pg(0, 60), (r2, e2) {
                    check(e2.type == JSONType.null_, "slow computer: the next listing answered");
                    check(remotesIn(r2) > 0, "slow computer: the next listing has the computer's photos");
                    plog("paging-test: slow computer: next listing has ", remotesIn(r2), " computer photos");
                    finish();
                });
            });
            wait.start();
        });
    }

    // PW_TEST_PAGE_DELAY==4000@2: the computer answers the first listing at once and a
    // refresh 4 s late. A photo taken meanwhile must be in the refresh within ~3 s, beside
    // the computer's photos the listing already had — not held back until the computer
    // answers, and without the grid shrinking.
    private bool rescanPending;
    private long remoteBefore;
    private string newPhoto;
    private void refreshTest()
    {
        import std.process : environment;
        import std.file : dirEntries, SpanMode, copy, append;
        import std.path : buildPath;
        import std.string : split, endsWith;

        core.request("library.page", pg(0, 60), (r, e) {
            check(e.type == JSONType.null_, "refresh: the first listing answered");
            remoteBefore = remotesIn(r);
            check(remoteBefore > 0, "refresh: the first listing has the computer's photos");
            // a photo "taken" now: a copy of one of the phone's, made unique
            immutable dir = environment.get("PW_PHONE_ROOTS", "").split(":")[0];
            foreach (f; dirEntries(dir, SpanMode.shallow))
                if (f.name.endsWith(".jpg"))
                {
                    newPhoto = buildPath(dir, "refresh-test-new.jpg");
                    copy(f.name, newPhoto);
                    append(newPhoto, cast(const(ubyte)[]) "refresh-test");
                    break;
                }
            rescanPending = true;
            core.request("library.rescan", JSONValue(null), (r2, e2) {});
        });
    }

    private void refreshStep2()
    {
        import core.time : MonoTime, seconds, msecs;
        import std.algorithm : canFind;
        import std.file : remove;

        auto params = pg(0, 61);   // one more than before: the new photo takes a place of its own
        params["refresh"] = true;
        immutable t0 = MonoTime.currTime;
        core.request("library.page", params, (r, e) {
            immutable took = MonoTime.currTime - t0;
            void cleanup() nothrow
            {
                try
                    remove(newPhoto);
                catch (Exception)
                {
                }
            }
            scope (exit)
                cleanup();
            check(e.type == JSONType.null_, "refresh answered (" ~ e.toString() ~ ")");
            if (e.type != JSONType.null_)
                return finish();
            check(took < 3500.msecs, "refresh answered before the slow computer (" ~ took.toString() ~ ")");
            check(remotesIn(r) == remoteBefore, "refresh kept the computer's photos ("
                ~ remotesIn(r).to!string ~ " of " ~ remoteBefore.to!string ~ ")");
            bool found;
            foreach (it; r["items"].array)
                if ("fileUrl" in it && it["fileUrl"].type == JSONType.string && it["fileUrl"].str.canFind("refresh-test-new"))
                    found = true;
            check(found, "refresh has the photo just taken");
            plog("paging-test: refresh after ", took, ": ", r["items"].array.length, " items, ",
                remotesIn(r), " computer photos, new photo ", found ? "in" : "MISSING");
            finish();
        });
    }

    private long remotesIn(JSONValue r)
    {
        long n;
        foreach (it; r["items"].array)
            if (isRemote(it))
                n++;
        return n;
    }

    // PW_TEST_PAGE_DELAY==25000@2: the first computer page answers, the second never does in
    // time. Walking to the end must reach the total the core reports (not promise the
    // computer photos it will no longer deliver).
    private void laterDeadline()
    {
        core.request("library.page", pg(0, 60), (r, e) { laterStep(r, e); });
    }

    private void laterStep(JSONValue r, JSONValue e)
    {
        check(e.type == JSONType.null_, "later-deadline page answered (" ~ e.toString() ~ ")");
        if (e.type != JSONType.null_)
            return finish();
        auto items = r["items"].array;
        all ~= items;
        if (items.length == 0)
        {
            check(r["total"].integer == all.length, "after a later page timed out: total "
                ~ r["total"].integer.to!string ~ " == walked " ~ all.length.to!string);
            plog("paging-test: later deadline: walked ", all.length, ", total ", r["total"].integer);
            return finish();
        }
        core.request("library.page", pg(all.length, 60), (r2, e2) { laterStep(r2, e2); });
    }

    private void finish()
    {
        import core.stdc.stdlib : exit;

        if (failures.length)
            plog("paging-test: FAIL ", failures.length, " check(s): ", failures);
        else
            plog("paging-test: PASS");
        exit(failures.length ? 1 : 0);
    }
}

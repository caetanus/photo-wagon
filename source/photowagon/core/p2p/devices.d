/// The phones paired with this desktop, keyed by their libp2p peer id (a stable,
/// cryptographic per-device fingerprint). The desktop names them and can pause or
/// revoke one; auth refuses a paused or revoked peer. A phone the desktop has never
/// seen is registered here the first time it authenticates.
module photowagon.core.p2p.devices;

import std.json;

import photowagon.core.db.sqlite : Database;

enum DeviceState : string
{
    active = "active",
    paused = "paused",
    revoked = "revoked",
}

struct Device
{
    string peerId;
    string name;
    string state;
    string pairedAt;
    string lastSeen;
}

/// Holds the phones waiting for the person at the desktop to authorize them. A new phone
/// shows a 4-digit code and sends it here; the desktop is told a device is knocking; when
/// the operator types the matching code, the pending connection is admitted and recorded.
/// The code lives only in memory and only until the connection is authorized or dropped.
final class PairingManager
{
    private struct Pending
    {
        string code;
        string name;
        void delegate(bool ok) resolve;   // called by confirm()/cancel(); admits or refuses the connection
    }

    private Pending[string] pending;   // peer id → what it is waiting on

    /// A phone (peer) is knocking with the code it shows and a suggested name; `resolve` is
    /// how its held connection is answered. Returns the previous waiter's resolve, if any,
    /// so the caller can refuse a superseded attempt.
    void begin(string peer, string code, string name, void delegate(bool) resolve)
    {
        if (auto p = peer in pending)
            p.resolve(false);   // a second attempt from the same phone: drop the first
        pending[peer] = Pending(code, name, resolve);
    }

    bool isPending(string peer) const
    {
        return (peer in pending) !is null;
    }

    /// The suggested name a pending phone sent (for the desktop's prompt).
    string pendingName(string peer)
    {
        auto p = peer in pending;
        return p ? p.name : null;
    }

    /// The operator typed `code` for `peer`. If it matches, admit and forget it; else refuse.
    bool confirm(string peer, string code)
    {
        auto p = peer in pending;
        if (p is null)
            return false;
        immutable ok = p.code == code;
        auto resolve = p.resolve;
        pending.remove(peer);
        if (resolve !is null)
            resolve(ok);
        return ok;
    }

    /// The connection went away before it was authorized.
    void cancel(string peer)
    {
        if (auto p = peer in pending)
        {
            pending.remove(peer);
        }
    }
}

final class DeviceRepo
{
    private Database db;

    this(Database db)
    {
        this.db = db;
    }

    /// Every device, most-recently-seen first.
    Device[] list()
    {
        Device[] out_;
        auto q = db.prepare(
            "SELECT peer_id, name, state, paired_at, COALESCE(last_seen, '') FROM devices ORDER BY last_seen DESC, paired_at DESC");
        while (q.step())
            out_ ~= Device(q.getString(0), q.getString(1), q.getString(2), q.getString(3), q.getString(4));
        return out_;
    }

    /// The state of a peer, or null if it is unknown.
    string stateOf(string peerId)
    {
        auto q = db.prepare("SELECT state FROM devices WHERE peer_id = ?");
        q.bind(1, peerId);
        return q.step() ? q.getString(0) : null;
    }

    bool exists(string peerId)
    {
        auto q = db.prepare("SELECT 1 FROM devices WHERE peer_id = ?");
        q.bind(1, peerId);
        return q.step();
    }

    /// Register a newly paired device (active), or leave an existing one as it is.
    void add(string peerId, string name)
    {
        auto q = db.prepare(
            "INSERT OR IGNORE INTO devices (peer_id, name, state, last_seen) VALUES (?, ?, 'active', datetime('now'))");
        q.bind(1, peerId).bind(2, name.length ? name : cast(string) null);
        q.run();
    }

    void rename(string peerId, string name)
    {
        auto q = db.prepare("UPDATE devices SET name = ? WHERE peer_id = ?");
        q.bind(1, name).bind(2, peerId);
        q.run();
    }

    void setState(string peerId, string state)
    {
        auto q = db.prepare("UPDATE devices SET state = ? WHERE peer_id = ?");
        q.bind(1, state).bind(2, peerId);
        q.run();
    }

    /// A revoked device is forgotten entirely: the next time it connects it is a new,
    /// unknown device that must be paired again.
    void remove(string peerId)
    {
        auto q = db.prepare("DELETE FROM devices WHERE peer_id = ?");
        q.bind(1, peerId);
        q.run();
    }

    void touch(string peerId)
    {
        auto q = db.prepare("UPDATE devices SET last_seen = datetime('now') WHERE peer_id = ?");
        q.bind(1, peerId);
        q.run();
    }

    JSONValue toJson(Device d) const
    {
        return JSONValue([
            "peerId": JSONValue(d.peerId),
            "name": JSONValue(d.name.length ? d.name : d.peerId[0 .. d.peerId.length > 12 ? 12 : $]),
            "state": JSONValue(d.state),
            "pairedAt": JSONValue(d.pairedAt),
            "lastSeen": JSONValue(d.lastSeen),
        ]);
    }
}

unittest
{
    import photowagon.core.db.schema : migrate;

    auto db = new Database(":memory:");
    scope (exit)
        db.close();
    migrate(db);
    auto repo = new DeviceRepo(db);
    assert(repo.stateOf("12D3peer") is null);
    repo.add("12D3peer", "Galaxy M62");
    assert(repo.stateOf("12D3peer") == "active");
    repo.add("12D3peer", "again");           // OR IGNORE: keeps the first name
    assert(repo.list().length == 1 && repo.list()[0].name == "Galaxy M62");
    repo.rename("12D3peer", "Meu telefone");
    assert(repo.list()[0].name == "Meu telefone");
    repo.setState("12D3peer", DeviceState.paused);
    assert(repo.stateOf("12D3peer") == "paused");
    repo.remove("12D3peer");
    assert(repo.stateOf("12D3peer") is null);
}

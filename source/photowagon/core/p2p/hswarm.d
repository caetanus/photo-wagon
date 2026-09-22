/// The phone↔desktop sync transport on hyperswarm/udx (Holepunch stack), the
/// replacement for the libp2p path. Both peers derive the SAME 32-byte topic from
/// the shared pairing secret; the desktop announces it (server) and the phone
/// discovers + connects (client). Each peer connection is a single end-to-end
/// encrypted bidirectional byte stream — Connection.write / onData — over a
/// hole-punched udx socket (no relay: punch-or-nothing, by design).
///
/// This is the transport only. The app protocol (auth, ipc frames, file push)
/// rides the byte stream and is framed by the caller, exactly as before — but over
/// ONE stream per peer, so bulk and control share it (see the note in P2pBridge
/// about not letting a large push starve the keepalive).
module photowagon.core.p2p.hswarm;

import hyperswarm.swarm : Hyperswarm;
import hyperswarm.connection : Connection;
import hyperswarm.cenc : Address;
import hyperswarm.noise.crypto : keyedBlake2b;
import vibe.core.net : NetworkAddress;

/// A hyperswarm node for one end of the phone↔desktop link.
final class HsTransport
{
    private Hyperswarm swarm;

    /// Invoked once per new peer connection, after its secret stream opens. The
    /// callee sets the Connection's onData/onClose and uses write() to send.
    void delegate(Connection) nothrow onPeer;

    /// `bootstrap` = the hyperdht bootstrap nodes to join the DHT through (the real
    /// public network in production; a throwaway node on the netns rig for tests).
    /// `seed` = this node's 32-byte ed25519 identity (reuse the existing identity
    /// seed so the peer key is stable across restarts).
    this(Address[] bootstrap, scope const(ubyte)[] seed)
    {
        swarm = new Hyperswarm(bootstrap, seed);
        swarm.onConnection = (Connection c) nothrow {
            if (onPeer !is null)
                onPeer(c);
        };
    }

    /// The rendezvous topic, derived identically on both sides from the shared
    /// pairing secret (domain-separated so it can't collide with other uses of it).
    static ubyte[32] topicFor(scope const(ubyte)[] pairingSecret) @trusted
    {
        ubyte[32] t; // a hyperswarm topic is 32 bytes (blake2b's default digest is 64)
        keyedBlake2b(t[], cast(const(ubyte)[])"photowagon:sync:1\0" ~ pairingSecret, null);
        return t;
    }

    /// Desktop side: announce the topic + announce-self and accept connections.
    /// Phone side: discover the topic's peer(s) and connect. Both fire onPeer.
    /// Join the swarm for the sharing KEY (the pairing token): the topic is derived
    /// here, and the LAN rendezvous for the same key is switched on — one mDNS
    /// label shared with the libp2p flavor, one TXT record with this flavor's line.
    void start(scope const(ubyte)[] key, bool asServer)
    {
        auto topic = topicFor(key);
        swarm.join(topic, /*client*/ !asServer, /*serverMode*/ asServer);
        startLan(key, asServer);
    }

    /// The older entry: a pre-derived topic, no LAN rendezvous (needs the key).
    void start(ubyte[32] topic, bool asServer)
    {
        swarm.join(topic, /*client*/ !asServer, /*serverMode*/ asServer);
    }

    /// This flavor's lines on the key's LAN rendezvous: the server announces
    /// `udx=<port>` and `pk=<public key>`; a client that hears them connects the
    /// udx transport straight to the answering address — no DHT, no punch. The
    /// libp2p flavor puts its own lines (`id=`, `quic=`, `tcp=`) on the same record.
    private void startLan(scope const(ubyte)[] key, bool asServer) nothrow
    {
        import std.conv : to;
        import std.format : format;
        import libp2p.discovery.mdns : LanRendezvous;

        try
        {
            auto lan = LanRendezvous.forKey("pw", key);
            auto sw = swarm;
            if (asServer)
                lan.addTxtSource(() => ["udx=" ~ sw.udxPort.to!string, "pk=" ~ format("%(%02x%)", sw.keyPair.publicKey[])]);
            else
                lan.addListener((NetworkAddress from, string[] txts) nothrow {
                    try
                    {
                        immutable portText = LanRendezvous.line(txts, "udx");
                        immutable pkText = LanRendezvous.line(txts, "pk");
                        if (portText.length == 0 || pkText.length != 64)
                            return; // no hyperswarm line in this answer
                        ubyte[32] pk;
                        foreach (i; 0 .. 32)
                            pk[i] = cast(ubyte) pkText[2 * i .. 2 * i + 2].to!int(16);
                        sw.connectAt(pk, Address(from.toAddressString, 4, portText.to!ushort));
                    }
                    catch (Exception)
                    {
                    }
                });
        }
        catch (Exception)
        {
            // no multicast here (a VPN-only host): the DHT path stands alone
        }
    }

    /// hyperdht's public bootstrap nodes (upstream hyperdht lib/constants
    /// BOOTSTRAP_NODES — the same nodes Keet uses, keeping that oracle valid),
    /// UNLESS PW_HS_BOOTSTRAP overrides them: a comma-separated "ip:port,ip:port"
    /// list, so desktop + phone can point at a throwaway bootstrap on the netns
    /// test rig and prove the stack end-to-end without depending on public nodes.
    static Address[] defaultBootstrap() @trusted
    {
        import std.process : environment;
        import std.string : split, strip, indexOf;
        import std.conv : to;

        auto env = environment.get("PW_HS_BOOTSTRAP", "");
        if (env.length)
        {
            Address[] over;
            foreach (tok; env.split(","))
            {
                auto s = tok.strip;
                immutable c = s.indexOf(':');
                if (c <= 0)
                    continue;
                try
                    over ~= Address(s[0 .. c].idup, 4, s[c + 1 .. $].to!ushort);
                catch (Exception)
                {
                }
            }
            if (over.length)
                return over;
        }
        return [
            Address("88.99.3.86", 4, 49_737),
            Address("142.93.90.113", 4, 49_737),
            Address("138.68.147.8", 4, 49_737),
        ];
    }

    /// This node's public key — what a peer authenticates us as.
    ref const(ubyte[32]) publicKey() const nothrow
    {
        return swarm.keyPair.publicKey;
    }
}

// TcpBridge — a core on another machine, reached over TCP.
//
// The desktop runs `photo-wagon --serve --ipc-address 0.0.0.0`; this bridge
// keeps one QTcpSocket to it, reconnecting on a 1 s timer, and remembers the
// endpoint in the app's config directory so the next launch reconnects alone.
module photowagon.mobile.tcpbridge;

import photowagon.mobile.plog : plog;

import qt.quick.qtcpsocket;
import qt.quick.qabstractsocket;
import qt.quick.qtimer;
import qt.quick.qstandardpaths;
import cppq = qt.quick.qobject;

import std.conv : to;
import std.file : exists, readText, write, mkdirRecurse;
import std.json;
import std.path : buildPath, dirName;
import std.stdio : writeln, stdout;
import std.string : strip, indexOf, startsWith, join;

import photowagon.core.pairingcode : PairingInfo, parsePairingCode, pairingCode;
import photowagon.ui.transport : Bridge, ResultCb;

final class TcpBridge : Bridge
{
    /// A QR code arrived (files/settings/scanned): whoever wraps this bridge hears too.
    void delegate(string code) onScanned;
    private QTcpSocket sock;
    private QTimer retry;
    private string host;
    private ushort port;
    private string token;      // from the QR code; empty for a plain host:port
    private string[] hosts;    // every "ip:port" the code offered; tried in turn
    private size_t hostIndex;
    private bool up;
    private bool authed;
    private string[] outbox;   // requests made while disconnected
    private string settingsFile;
    private string scannedFile; // written by MainActivity after a QR scan

    this()
    {
        immutable dir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppConfigLocation).toString();
        settingsFile = buildPath(dir, "endpoint");
        // the Java side writes here: <app files>/settings/scanned
        immutable files = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation).toString();
        scannedFile = buildPath(files, "settings", "scanned");
        loadEndpoint();
    }

    /// Applies a `pw://token@host:port,…` code (from the QR, or typed).
    void setPairingCode(string code)
    {
        PairingInfo info;
        try
            info = parsePairingCode(code);
        catch (Exception e)
        {
            plog("bridge: bad code: ", e.msg);
            return;
        }
        token = info.token;
        hosts = info.hosts;
        hostIndex = 0;
        applyHost(hosts[0]);
        saveEndpoint();
        reconnect();
    }

    private void applyHost(string hp)
    {
        immutable colon = hp.indexOf(':');
        if (colon <= 0)
            return;
        host = hp[0 .. colon];
        try
            port = hp[colon + 1 .. $].to!ushort;
        catch (Exception)
            port = 0;
    }

    private void reconnect()
    {
        if (sock is null)
            return;
        if (sock.state() != QAbstractSocket.SocketState.UnconnectedState)
            sock.abort();       // emits disconnected → failAll, then tick reconnects
        up = false;
        tick();
    }

    override void start()
    {
        sock = new QTcpSocket(cast(cppq.QObject) null);
        sock.connectReadyRead(&onReadyRead);
        sock.connectConnected(&onSockConnected);
        sock.connectDisconnected(&onSockDisconnected);
        sock.connectErrorOccurred(&onSockError);

        retry = new QTimer(cast(cppq.QObject) null);
        retry.setInterval(1000);
        retry.connectTimeout(&tick);
        tick();
        retry.start();
    }

    override bool connected() const { return up; }
    override bool remote() const { return true; }

    override string endpoint() const
    {
        return host.length ? host ~ ":" ~ port.to!string : "";
    }

    override void setEndpoint(string newHost, ushort newPort)
    {
        if (newHost.startsWith("pw://"))
        {
            setPairingCode(newHost);
            return;
        }
        // "host:port" in the host field is accepted too
        immutable colon = newHost.indexOf(':');
        if (colon > 0 && newPort == 0)
        {
            try
                newPort = newHost[colon + 1 .. $].to!ushort;
            catch (Exception) {}
            newHost = newHost[0 .. colon];
        }
        if (newHost.length == 0 || newPort == 0)
            return;
        host = newHost;
        port = newPort;
        token = null;
        hosts = [host ~ ":" ~ port.to!string];
        hostIndex = 0;
        saveEndpoint();
        reconnect();
    }

    override void request(string method, JSONValue params, ResultCb cb)
    {
        immutable line = enqueue(method, params, cb);
        if (up && authed)
            sock.write(line);
        else
            outbox ~= line;
    }

    // ---- connection lifecycle -------------------------------------------------

    private void tick()
    {
        pollScanned();
        if (host.length == 0)
            return;
        if (sock.state() != QAbstractSocket.SocketState.UnconnectedState)
            return;
        sock.connectToHost(host, port, 3 /* ReadWrite */, QAbstractSocket.NetworkLayerProtocol.AnyIPProtocol);
    }

    /// A QR scan landed in the file MainActivity writes: adopt it and connect.
    private void pollScanned()
    {
        if (!scannedFile.exists)
            return;
        string code;
        try
        {
            code = readText(scannedFile).strip();
            import std.file : remove;
            remove(scannedFile);
        }
        catch (Exception) { return; }
        plog("bridge: scanned ", code);
        setPairingCode(code);
        if (onScanned)
            onScanned(code);
    }

    private void onSockConnected()
    {
        up = true;
        authed = token.length == 0;
        plog("bridge: connected to ", endpoint, token.length ? " (pairing token)" : "");
        if (token.length)
        {
            // the door is locked from the network: unlock it before anything else
            JSONValue params = ["token": JSONValue(token)];
            immutable line = enqueue("daemon.auth", params, (r, e) {
                // an older core without daemon.auth, or one that already trusts us: carry on
                if (e.type != JSONType.null_ && !(e.type == JSONType.object && "code" in e && e["code"].str == "unknown_method"))
                {
                    plog("bridge: pairing refused: ", e.toString());
                    return;
                }
                authed = true;
                flush();
            });
            sock.write(line);
        }
        else
            flush();
        if (onConnected)
            onConnected(true);
    }

    private void flush()
    {
        foreach (line; outbox)
            sock.write(line);
        outbox.length = 0;
    }

    private void onSockDisconnected()
    {
        if (!up)
            return;
        up = false;
        plog("bridge: disconnected");
        failAll("disconnected");
        if (onConnected)
            onConnected(false);
    }

    private void onSockError(QAbstractSocket.SocketError err)
    {
        if (up)
            onSockDisconnected();
        else if (hosts.length > 1)
        {
            // the code listed several addresses; try the next one
            hostIndex = (hostIndex + 1) % hosts.length;
            applyHost(hosts[hostIndex]);
        }
    }

    private void onReadyRead()
    {
        while (sock.canReadLine())
            deliverLine(sock.readLine(0).toString());
    }

    // ---- persistence -------------------------------------------------------------

    private void loadEndpoint()
    {
        if (!settingsFile.exists)
            return;
        try
        {
            auto v = readText(settingsFile).strip();
            if (v.startsWith("pw://"))
            {
                auto info = parsePairingCode(v);
                token = info.token;
                hosts = info.hosts;
                applyHost(hosts[0]);
                return;
            }
            immutable colon = v.indexOf(':');
            if (colon > 0)
            {
                host = v[0 .. colon];
                port = v[colon + 1 .. $].to!ushort;
                hosts = [v];
            }
        }
        catch (Exception) {}
    }

    private void saveEndpoint()
    {
        try
        {
            mkdirRecurse(settingsFile.dirName);
            write(settingsFile, (token.length ? "pw://" ~ token ~ "@" ~ hostsJoined() : endpoint) ~ "\n");
        }
        catch (Exception e)
        {
            plog("bridge: cannot save endpoint: ", e.msg);
        }
    }

    private string hostsJoined() const
    {
        return hosts.join(",");
    }
}

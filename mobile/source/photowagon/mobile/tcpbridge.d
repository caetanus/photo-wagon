// TcpBridge — a core on another machine, reached over TCP.
//
// The desktop runs `photo-wagon --serve --ipc-address 0.0.0.0`; this bridge
// keeps one QTcpSocket to it, reconnecting on a 1 s timer, and remembers the
// endpoint in the app's config directory so the next launch reconnects alone.
module photowagon.mobile.tcpbridge;

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
import std.string : strip, indexOf;

import photowagon.ui.transport : Bridge, ResultCb;

final class TcpBridge : Bridge
{
    private QTcpSocket sock;
    private QTimer retry;
    private string host;
    private ushort port;
    private bool up;
    private string[] outbox;   // requests made while disconnected
    private string settingsFile;

    this()
    {
        immutable dir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppConfigLocation).toString();
        settingsFile = buildPath(dir, "endpoint");
        loadEndpoint();
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
        saveEndpoint();
        if (sock is null)
            return;
        if (sock.state() != QAbstractSocket.SocketState.UnconnectedState)
            sock.abort();       // emits disconnected → failAll, then tick reconnects
        up = false;
        tick();
    }

    override void request(string method, JSONValue params, ResultCb cb)
    {
        immutable line = enqueue(method, params, cb);
        if (up)
            sock.write(line);
        else
            outbox ~= line;
    }

    // ---- connection lifecycle -------------------------------------------------

    private void tick()
    {
        if (host.length == 0)
            return;
        if (sock.state() != QAbstractSocket.SocketState.UnconnectedState)
            return;
        sock.connectToHost(host, port, 3 /* ReadWrite */, QAbstractSocket.NetworkLayerProtocol.AnyIPProtocol);
    }

    private void onSockConnected()
    {
        up = true;
        writeln("bridge: connected to ", endpoint); stdout.flush();
        foreach (line; outbox)
            sock.write(line);
        outbox.length = 0;
        if (onConnected)
            onConnected(true);
    }

    private void onSockDisconnected()
    {
        if (!up)
            return;
        up = false;
        writeln("bridge: disconnected"); stdout.flush();
        failAll("disconnected");
        if (onConnected)
            onConnected(false);
    }

    private void onSockError(QAbstractSocket.SocketError err)
    {
        if (up)
            onSockDisconnected();
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
            immutable colon = v.indexOf(':');
            if (colon > 0)
            {
                host = v[0 .. colon];
                port = v[colon + 1 .. $].to!ushort;
            }
        }
        catch (Exception) {}
    }

    private void saveEndpoint()
    {
        try
        {
            mkdirRecurse(settingsFile.dirName);
            write(settingsFile, endpoint ~ "\n");
        }
        catch (Exception e)
        {
            writeln("bridge: cannot save endpoint: ", e.msg); stdout.flush();
        }
    }
}

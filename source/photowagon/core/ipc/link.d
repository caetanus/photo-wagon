/// The in-process transport between the UI thread and the core thread.
///
/// Same line protocol as the socket (docs/ipc.md), but the lines travel through
/// two queues under a mutex. The core is woken through a shared vibe event; the
/// UI is woken through a pipe it can hand to a `QSocketNotifier` (or poll).
/// Nothing here knows about Qt or about fibers beyond the wake-up itself.
module photowagon.core.ipc.link;

import core.sync.mutex : Mutex;
import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.sys.posix.unistd : pipe, read, write, close;

import vibe.core.sync : ManualEvent, createSharedManualEvent;

final class InProcessLink
{
	private Mutex lock;
	private string[] inbox; // UI → core
	private string[] outbox; // core → UI
	private shared(ManualEvent) wake;
	private int[2] fds;
	private bool signalled; // "a wake byte is in flight"; guarded by `lock`, same as outbox

	private bool vibeWake;

	/// `vibeWake`: wake the core side through vibe's shared event (the desktop core
	/// waits on it). The phone's libp2p thread polls instead and passes false: on
	/// Android that event ended in vibe's "May not process events within an active
	/// yieldLock()" and took the event loop down.
	this(bool vibeWake = true)
	{
		this.vibeWake = vibeWake;
		lock = new Mutex;
		if (vibeWake)
			wake = createSharedManualEvent();
		if (pipe(fds) != 0)
			throw new Exception("cannot create wake pipe");
		foreach (fd; fds)
			fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	}

	// ---- UI side ------------------------------------------------------------------

	/// Queues a request line and wakes the core.
	void submit(string line)
	{
		synchronized (lock)
			inbox ~= line;
		if (vibeWake)
			wake.emit();
	}

	/// Everything the core produced since the last call. Also clears the wake pipe.
	string[] takeOutbox()
	{
		// Drain the pipe first, then take the outbox and drop `signalled` together under the
		// lock. Doing it in this order, with `signalled` guarded by the same lock as `outbox`,
		// keeps the two in step: after this returns, the outbox is empty and any later deliver
		// sees signalled == false and writes a fresh wake byte. The old code flipped a lock-free
		// `signalled` outside the outbox lock, which could leave it stuck true with an empty
		// pipe — after which no deliver ever woke the UI again and every later response (a page,
		// the stats) sat unread. Under a phone sync's event volume that raced often: an empty
		// library while Places, answered earlier, still showed.
		ubyte[64] sink;
		while (read(fds[0], sink.ptr, sink.length) > 0)
		{
		}
		string[] out_;
		synchronized (lock)
		{
			out_ = outbox;
			outbox = null;
			signalled = false;
		}
		return out_;
	}

	/// Readable whenever `takeOutbox` has something to give.
	int wakeFd() const
	{
		return fds[0];
	}

	// ---- core side ------------------------------------------------------------------

	string[] takeInbox()
	{
		string[] out_;
		synchronized (lock)
		{
			out_ = inbox;
			inbox = null;
		}
		return out_;
	}

	/// Queues a response or event line for the UI and wakes it once.
	void deliver(string line) nothrow
	{
		bool wasSignalled = true; // if the lock throws, skip the write
		try
		{
			synchronized (lock)
			{
				outbox ~= line;
				wasSignalled = signalled;
				signalled = true;
			}
		}
		catch (Exception)
		{
			return;
		}
		if (!wasSignalled) // only the first pending message writes a wake byte
		{
			ubyte one = 1;
			write(fds[1], &one, 1);
		}
	}

	int emitCount()
	{
		return wake.emitCount;
	}

	/// Blocks the calling fiber until the UI submitted something after `seen`.
	int waitForInput(int seen)
	{
		return wake.wait(seen);
	}

	void dispose() nothrow
	{
		foreach (ref fd; fds)
			if (fd >= 0)
			{
				close(fd);
				fd = -1;
			}
	}
}

unittest
{
	auto l = new InProcessLink;
	scope (exit)
		l.dispose();
	l.deliver("a\n");
	l.deliver("b\n");
	ubyte[8] probe;
	assert(read(l.wakeFd, probe.ptr, 8) == 1); // one byte for two lines
	assert(l.takeOutbox() == ["a\n", "b\n"]);
	assert(l.takeOutbox().length == 0);
	l.deliver("c\n");
	assert(read(l.wakeFd, probe.ptr, 8) == 1); // re-armed after the take
	l.submit("x");
	assert(l.takeInbox() == ["x"]);
}

/// The vision worker: OpenCV — the CLIP encoder, the face detector and recogniser —
/// in a child process. Inside the app these models and their buffers grew the
/// process by a gigabyte and kept growing; here the core starts
/// `photo-wagon --vision-worker` for a pass, talks to it over pipes one line per
/// request, and kills it when the pass is over. Whatever OpenCV keeps, the system
/// gets back. The worker itself is the one place csrc/*_opencv is called.
///
/// Protocol (one line each way, the worker answers "ready" first):
///   clip <path>                       → ok f0 … f511 | err <message>
///   face <maxEdge> <edgeHint> <path>  → ok <n> {x y w h score e0 … e127}×n | err <message>
/// Blocking I/O, meant for a worker thread (`async`), serialised by a mutex.
module photowagon.core.vision.worker;

import core.sync.mutex : Mutex;
import std.array : split;
import std.conv : to;
import std.process : ProcessPipes, Redirect, pipeProcess, kill, wait, tryWait;
import std.stdio : stdin, stdout;
import std.string : strip, startsWith;

/// The model files the worker is started with (empty = that model is off).
struct VisionModels
{
	string clip;
	string yunet;
	string sface;
}

// ---- the parent side ---------------------------------------------------------------

private __gshared Mutex lock;
private __gshared ProcessPipes proc;
private __gshared bool up;
private __gshared VisionModels models;

shared static this()
{
	lock = new Mutex;
}

/// Which models a worker started from now on will load.
void configureVision(VisionModels m)
{
	synchronized (lock)
		models = m;
}

private void spawn()
{
	import std.file : thisExePath;

	proc = pipeProcess([thisExePath, "--vision-worker", models.clip, models.yunet, models.sface, "--exit-with-parent"],
		Redirect.stdin | Redirect.stdout);
	auto first = proc.stdout.readln().strip;
	if (first != "ready")
	{
		try
		{
			kill(proc.pid);
			wait(proc.pid);
		}
		catch (Exception)
		{
		}
		up = false;
		throw new Exception("vision worker did not start: " ~ (first.length ? first : "no answer"));
	}
	up = true;
}

/// Starts the worker now (a pass calls this first, so the load is not on its first photo).
void startVision()
{
	synchronized (lock)
		if (!up)
			spawn();
}

/// Ends the worker: its memory goes back to the system. The next request starts another.
void releaseVision() nothrow
{
	try
		synchronized (lock)
		{
			if (!up)
				return;
			up = false;
			proc.stdin.close();      // EOF: the worker leaves by itself …
			import core.thread : Thread;
			import core.time : msecs;
			foreach (i; 0 .. 20)
			{
				if (tryWait(proc.pid).terminated)
					return;
				Thread.sleep(50.msecs);
			}
			kill(proc.pid);          // … or not
			wait(proc.pid);
		}
	catch (Exception)
	{
	}
}

/// One request, one answer; a dead worker is replaced once. Throws on "err".
string visionRequest(string line)
{
	synchronized (lock)
	{
		if (!up)
			spawn();
		string answer;
		try
		{
			proc.stdin.writeln(line);
			proc.stdin.flush();
			answer = proc.stdout.readln().strip;
		}
		catch (Exception)
			answer = null;
		if (answer is null || !answer.length)
		{
			// the worker died (a bad file, or its own memory guard): once more with a fresh one
			up = false;
			try
				wait(proc.pid);
			catch (Exception)
			{
			}
			spawn();
			proc.stdin.writeln(line);
			proc.stdin.flush();
			answer = proc.stdout.readln().strip;
		}
		if (answer.startsWith("err "))
			throw new Exception(answer[4 .. $]);
		if (!answer.startsWith("ok"))
			throw new Exception("vision worker: bad answer to '" ~ line ~ "'");
		return answer.length > 3 ? answer[3 .. $] : "";
	}
}

// ---- the child --------------------------------------------------------------------

private extern (C) nothrow @nogc
{
	int pw_clip_init(const char* onnx);
	void pw_clip_release();
	int pw_clip_encode(const char* path, float* out512);
	int pw_face_init(const char* yunet, const char* sface);
	struct PwFace
	{
		float x, y, w, h;
		float score;
		float[128] embedding;
	}

	int pw_face_detect(const char* path, int maxEdge, int edgeHint, PwFace* out_, int maxFaces);
}

/// `photo-wagon --vision-worker <clip> <yunet> <sface>`: models load on first use,
/// stdin lines are requests, stdout lines answers; ends with stdin.
int runVisionWorker(VisionModels m)
{
	import std.string : toStringz;

	bool clipLoaded, facesLoaded;
	stdout.writeln("ready");
	stdout.flush();
	foreach (line; stdin.byLineCopy)
	{
		auto req = line.strip;
		if (!req.length)
			continue;
		string out_;
		try
		{
			if (req.startsWith("clip "))
			{
				if (!clipLoaded)
				{
					if (!m.clip.length || pw_clip_init(m.clip.toStringz) != 0)
						throw new Exception("cannot load the CLIP image model (" ~ m.clip ~ ")");
					clipLoaded = true;
				}
				float[512] e = void;
				if (pw_clip_encode(req[5 .. $].toStringz, e.ptr) != 0)
					throw new Exception("CLIP encoding failed for " ~ req[5 .. $]);
				out_ = "ok";
				foreach (v; e)
					out_ ~= " " ~ v.to!string;
			}
			else if (req.startsWith("face "))
			{
				auto parts = req[5 .. $].split(' ');
				if (parts.length < 3)
					throw new Exception("face: bad request");
				immutable maxEdge = parts[0].to!int, hint = parts[1].to!int;
				immutable path = req[5 + parts[0].length + 1 + parts[1].length + 1 .. $];
				if (!facesLoaded)
				{
					if (!m.yunet.length || pw_face_init(m.yunet.toStringz, m.sface.toStringz) != 0)
						throw new Exception("cannot load the face models (" ~ m.yunet ~ ", " ~ m.sface ~ ")");
					facesLoaded = true;
				}
				PwFace[64] raw = void;
				immutable n = pw_face_detect(path.toStringz, maxEdge, hint, raw.ptr, cast(int) raw.length);
				if (n < 0)
					throw new Exception("face detection failed for " ~ path);
				out_ = "ok " ~ n.to!string;
				foreach (i; 0 .. n)
				{
					out_ ~= " " ~ raw[i].x.to!string ~ " " ~ raw[i].y.to!string ~ " " ~ raw[i].w.to!string ~ " "
						~ raw[i].h.to!string ~ " " ~ raw[i].score.to!string;
					foreach (v; raw[i].embedding)
						out_ ~= " " ~ v.to!string;
				}
			}
			else
				throw new Exception("unknown request");
		}
		catch (Exception e)
			out_ = "err " ~ e.msg;
		stdout.writeln(out_);
		stdout.flush();
	}
	if (clipLoaded)
		pw_clip_release();
	return 0;
}

/// `dub test` entry point: the unittests in each module run before main.
module runner;

void main()
{
	import std.stdio : writeln;

	writeln("photowagond: unit tests passed");
}

module html.utils;


import std.ascii;


package bool isSpace(Char)(Char ch) {
	return (ch == 32) || ((ch >= 9) && (ch <= 13));
}


package bool equalsCI(CharA, CharB)(const(CharA)[] a, const(CharB)[] b) {
	if (a.length == b.length) {
		for (uint i = 0; i < a.length; ++i) {
			if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i]))
				return false;
		}
		return true;
	}
	return false;
}


package size_t tagHashOf(const(char)[] x) {
	size_t hash = 5381;
	foreach(i; 0..x.length)
		hash = (hash * 33) ^ cast(size_t)(std.ascii.toLower(x.ptr[i]));
	return hash;
}

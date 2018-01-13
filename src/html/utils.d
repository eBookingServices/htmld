module html.utils;


import std.ascii;
import std.typecons;


bool isSpace(Char)(Char ch) {
	return (ch == 32) || ((ch >= 9) && (ch <= 13));
}


bool equalsCI(CharA, CharB)(const(CharA)[] a, const(CharB)[] b) {
	if (a.length == b.length) {
		for (uint i = 0; i < a.length; ++i) {
			if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i]))
				return false;
		}
		return true;
	}
	return false;
}


size_t quickHashOf(const(char)[] x) {
	size_t hash = 5381;
	foreach(i; 0..x.length)
		hash = (hash * 33) ^ cast(size_t)(x.ptr[i]);
	return hash;
}


size_t tagHashOf(const(char)[] x) {
	size_t hash = 5381;
	foreach(i; 0..x.length)
		hash = (hash * 33) ^ cast(size_t)(std.ascii.toLower(x.ptr[i]));
	return hash;
}


void writeHTMLEscaped(Flag!q{escapeQuotes} escapeQuotes, Appender)(ref Appender app, const(char)[] x) {
	foreach (dchar ch; x) {
		switch (ch) {
			static if (escapeQuotes) {
				case '"':
					app.put("&#34;"); // shorter than &quot;
					static assert('"' == 34);
					break;
			}
			case '<':
				app.put("&lt;");
				break;
			case '>':
				app.put("&gt;");
				break;
			case '&':
				app.put("&amp;");
				break;
			default:
				app.put(ch);
				break;
		}
	}
}

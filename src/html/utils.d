module html.utils;


import std.ascii;
import std.typecons;


bool isAllWhite(Char)(Char[] value) {
	auto ptr = value.ptr;
	const end = ptr + value.length;

	while (ptr != end) {
		if (!isWhite(*ptr++))
			return false;
	}
	return true;
}


bool requiresQuotes(Char)(Char[] value) {
	auto ptr = value.ptr;
	const end = ptr + value.length;

	while (ptr != end) {
		switch (*ptr++) {
		case 'a': .. case 'z':
		case 'A': .. case 'Z':
		case '0': .. case '9':
		case '-':
		case '_':
		case '.':
		case ':':
			continue;
		default:
			return true;
		}
	}
	return false;
}


bool equalsCI(CharA, CharB)(const(CharA)[] a, const(CharB)[] b) {
	if (a.length == b.length) {
		for (size_t i; i < a.length; ++i) {
			if (std.ascii.toLower(a.ptr[i]) != std.ascii.toLower(b.ptr[i]))
				return false;
		}
		return true;
	}
	return false;
}


enum QuickHash64Seed = 14695981039346656037u;
enum QuickHash64Scale = 1099511628211u;


ulong quickHash64(const(char)* p, const(char)* pend, ulong hash = QuickHash64Seed) {
	while (p != pend)
		hash = (hash ^ cast(ulong)(*p++)) * QuickHash64Scale;
	return hash;
}


ulong quickHash64i(const(char)* p, const(char)* pend, ulong hash = QuickHash64Seed) {
	while (p != pend)
		hash = (hash ^ cast(ulong)(std.ascii.toLower(*p++))) * QuickHash64Scale;
	return hash;
}


hash_t quickHashOf(const(char)[] x) {
	return cast(hash_t)quickHash64(x.ptr, x.ptr + x.length);
}


hash_t tagHashOf(const(char)[] x) {
	return cast(hash_t)quickHash64i(x.ptr, x.ptr + x.length);
}


void writeQuotesEscaped(Appender)(ref Appender app, const(char)[] x) {
	foreach (dchar ch; x) {
		switch (ch) {
			case '"':
				app.put("&#34;"); // shorter than &quot;
				static assert('"' == 34);
				break;
			default:
				app.put(ch);
				break;
		}
	}
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

module html.utils;


import std.ascii;
import std.format;
import std.utf;


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


void writeHTMLEscaped(Appender)(ref Appender app, const(char)[] x) {
	foreach (ch; x.byDchar) {
		switch (ch) {
			case '"':
				app.put("&quot;");
				break;
			case '\'':
				app.put("&#39;");
				break;
			case 'a': .. case 'z':
				goto case;
			case 'A': .. case 'Z':
				goto case;
			case '0': .. case '9':
				goto case;
			case ' ', '\t', '\n', '\r', '-', '_', '.', ':', ',', ';',
				'#', '+', '*', '?', '=', '(', ')', '/', '!',
				'%' , '{', '}', '[', ']', '$', '^', '~':
				app.put(cast(char)ch);
				break;
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
				formattedWrite(&app, "&#%d;", cast(uint)ch);
				break;
		}
	}
}

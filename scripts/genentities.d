import std.algorithm;
import std.array;
import std.bitmanip;
import std.conv;
import std.file;
import std.json;
import std.stdio;
import std.utf;


void main() {
    auto text = readText("entities.json");
    auto json = parseJSON(text);
    assert(json.type == JSON_TYPE.OBJECT);

    ubyte[] codes;
    uint[string] offsets;

    auto dchars = uninitializedArray!(dchar[])(32);
	auto minlen = int.max;
	auto maxlen = int.min;
    foreach(string key, value; json) {
        assert(value.type == JSON_TYPE.OBJECT);
        auto codepoints = value["codepoints"];

        dchars.length = codepoints.array.length;
        foreach(uint i, dcharjson; codepoints)
            dchars[i] = cast(dchar)dcharjson.integer;

        uint offset = codes.length;

        auto code = cast(ubyte[])toUTF8(dchars);
        auto found = codes.find(code);
        if (found.length) {
            offset = codes.length - found.length;
        } else {
            codes ~= cast(ubyte[])toUTF8(dchars);
        }
        uint length = code.length;

        assert(offset < (1 << 28));
        assert(length < (1 << 4));
        offset = (offset << 4) | length;

        if (key.front == '&')
            key = key[1..$];
        if (key.back == ';')
            key = key[0..$-1];

        offsets[key] = offset;
		minlen = min(key.length, minlen);
		maxlen = max(key.length, maxlen);
    }

    auto output = appender!(const(char)[]);

    output.put("__gshared immutable static ubyte[");
    output.put(codes.length.to!string);
    output.put("] bytes_ = ");
    output.put(codes.to!string.replace(", ", ","));
    output.put(";\n");
    output.put("__gshared immutable static uint[const(char)[]] index_ = ");
    output.put(offsets.to!string.replace(", ", ","));
    output.put(";\n");
	output.put("enum MinEntityNameLength = ");
	output.put(minlen.to!string);
	output.put(";\n");
	output.put("enum MaxEntityNameLength = ");
	output.put(maxlen.to!string);
	output.put(";\n");

    std.file.write("entities.d.mixin", output.data);
}
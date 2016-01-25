# htmld [![Build Status](https://travis-ci.org/eBookingServices/htmld.svg?branch=master)](https://travis-ci.org/eBookingServices/htmld)
Lightweight and forgiving HTML parser and DOM.

The parser was inspired by [htmlparse2](https://github.com/fb55/htmlparser2) by [fb55](https://github.com/fb55)

HTML Entity parsing and decoding are both optional. The current parser interface is based on callbacks.


Creating the DOM from source:
```d
auto doc = createDocument(`<html><body>&nbsp;</body></html>`);
writeln(doc.root.outerHTML);
```


Creating/mutating DOM manually:
```d
auto doc = createDocument();
doc.root.html = `<body>&nbsp;</body>`;

auto container = doc.createElement("div", doc.root.firstChild);
container.attr("class", "container");
container.html = "<p>moo!</p>";

auto app = appender!string;
doc.root.outerHTML(app);
```


QuerySelector interface:
```d
if (auto p = doc.querySelector("p:nth-of-type(2)"))
    p.text = "mooo";

foreach(p; doc.querySelectorAll("p")) {
    p.text = "mooo";
}
```


Example parser usage:
```d
auto builder = DOMBuilder();
parseHTML(`<html><body>&nbsp;</body></html>`, builder);
```


Example handler:
```d
struct DOMBuilder {
    void onText(const(char)[] data) {}
    void onSelfClosing() {}
    void onOpenStart(const(char)[] data) {}
    void onOpenEnd(const(char)[] data) {}
    void onClose(const(char)[] data) {}
    void onAttrName(const(char)[] data) {}
    void onAttrEnd() {}
    void onAttrValue(const(char)[] data) {}
    void onComment(const(char)[] data) {}
    void onDeclaration(const(char)[] data) {}
    void onProcessingInstruction(const(char)[] data) {}
    void onCDATA(const(char)[] data) {}

    // the following are required if ParseEntities is set
    void onNamedEntity(const(char)[] data) {}
    void onNumericEntity(const(char)[] data) {}
    void onHexEntity(const(char)[] data) {}
    
    // required only if DecodeEntities is set
    void onEntity(const(char)[] data, const(char)[] decoded) {}
    
    void onDocumentEnd() {}
}
```


# todo
- implement range-based interface for parser

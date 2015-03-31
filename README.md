# htmld
Lightweight and forgiving HTML parser inspired by [htmlparse2](https://github.com/fb55/htmlparser2) by [fb55](https://github.com/fb55)

HTML Entity parsing and decoding are both optional.
The current interface is based on callbacks.

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
}
```

Example usage:
```d
auto builder = DOMBuilder();
parseHTML(`<html><body>&nbsp;</body></html>`, builder);
```

# todo
- implement range-based interface
- implement DOM builder

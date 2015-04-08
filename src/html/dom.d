module html.dom;


import std.array;
import std.algorithm;

import html.parser;
import html.alloc;


alias HTMLString = const(char)[];


enum DOMCreateOptions {
    DecodeEntities  = 1 << 0,

    Default = DecodeEntities,
}


private struct ChildrenForward(ElementType) {
    this(ElementType* first) {
        while (first && !first.isElement)
            first = first.next_;
        curr_ = first;
    }

    bool empty() const {
        return (curr_ == null);
    }

    ElementWrapper!ElementType front() {
        return ElementWrapper!ElementType(curr_);
    }

    void popFront() {
        curr_ = curr_.next_;
        while (curr_) {
            if (curr_.isElement)
                break;
            curr_ = curr_.next_;
        }
    }

    private ElementType* curr_;
}


// depth first traversal
private struct DescendantsDFForward(ElementType) {
    this(ElementType* first) {
        while (first && !first.isElement)
            first = first.next_;
        curr_ = first;
    }

    bool empty() const {
        return (curr_ == null);
    }

    ElementWrapper!ElementType front() {
        return ElementWrapper!ElementType(curr_);
    }

    void popFront() {
        while (curr_) {
            if (curr_.firstChild_) {
                curr_ = curr_.firstChild_;
            } else {
                ElementType* next = curr_.next_;
                if (!next) {
                    ElementType* parent = curr_.parent_;
                    while (parent) {
                        if (parent.next_)
                            break;
                        parent = parent.parent_;
                    }
                    if (parent) 
                        next = parent.next_;
                }

                curr_ = next;
                if (!curr_)
                    break;
            }

            if (curr_.isElement)
                break;
        }
    }

    private ElementType* curr_;
}


struct ElementWrapper(ElementType) {
    package this(ElementType* element) {
        element_ = element;
    }

    alias element_ this;
    ElementType* element_;

    auto opIndex(HTMLString name) const {
        return element_.attr(name);
    }

    void opIndexAssign(T)(T value, HTMLString name) {
        import std.conv;
        element_.attr(name, value.to!string);
    }

    @property auto id() const {
        return element_.attr("id");
    }

    @property void id(T)(T value) {
        import std.conv;
        element_.attr("id", value.to!string);
    }

    auto toString() const {
        return element_.toString();
    }
}


struct Element {
    package this(Document* document, HTMLString tag) {
        tag_ = tag;
        document_ = document;
    }

    @property auto tag() {
        assert(isElement);
        return tag_;
    }

    void text(Appender)(ref Appender app) const {
        const(Element)* child = firstChild_;
        while (child) {
            if (!child.isElement) {
                app.put(child.tag_);
            } else {
                child.text(app);
            }
            child = child.next_;
        }
    }

    @property auto text() {
        Appender!HTMLString app;
        text(app);
        return app.data;
    }

    @property void text(HTMLString text) {
        destroyChildren();
        appendText(text);
    }

    @property void attr(HTMLString name, HTMLString value) {
        attrs_[name] = value;
    }

    @property auto attr(HTMLString name) const {
        if (auto pattr = name in attrs_)
            return *pattr;
        return null;
    }

    bool hasAttr(HTMLString name) const {
        return (name in attrs_) != null;
    }

    void removeAttr(HTMLString name) {
        attrs_.remove(name);
    }

    @property void html(size_t options = DOMCreateOptions.Default)(HTMLString html) {
        enum parserOptions = ((options & DOMCreateOptions.DecodeEntities) ? ParserOptions.DecodeEntities : 0);

        destroyChildren();

        auto builder = DOMBuilder!(Document)(*document_, &this);
        parseHTML!(typeof(builder), parserOptions)(html, builder);
    }

    @property auto html() {
        Appender!HTMLString app;
        innerHTML(app);
        return app.data;
    }

    @property auto outerHTML() {
        Appender!HTMLString app;
        outerHTML!(typeof(app))(app);
        return app.data;
    }

    void appendChild(Element* element) {
        if (element.parent_)
            element.detach();
        element.parent_ = &this;
        if (lastChild_) {
            assert(!lastChild_.next_);
            lastChild_.next_ = element;
            element.prev_ = lastChild_;
            lastChild_ = element;
        } else {
            assert(!firstChild_);
            firstChild_ = element;
            lastChild_ = element;
        }
    }

    void removeChild(Element* element) {
        assert(element.parent_ == &this);
        element.detach();
    }

    void destroyChildren() {
        auto child = firstChild_;
        while (child) {
            auto next = child.next_;
            child.destroy();
            child = next;
        }

        firstChild_ = null;
        lastChild_ = null;
    }

    void appendText(HTMLString text) {
        if (lastChild_ && !lastChild_.isElement) {
            lastChild_.tag_ ~= text;
        } else {
            auto element = document_.createElement(null);
            element.tag_ = text;
            element.flags_ |= Flags.Text;
            if (lastChild_) {
                assert(lastChild_.next_ == null);
                lastChild_.next_ = element;
                element.prev_ = lastChild_;
                lastChild_ = element;
            } else {
                assert(firstChild_ == null);
                firstChild_ = element;
                lastChild_ = element;
            }
            element.parent_ = &this;
        }
    }

    void insertBefore(Element* element) {
        assert(document_ == element.document_);

        parent_ = element.parent_;
        prev_ = element.prev_;
        next_ = element;
        element.prev_ = &this;

        if (parent_ && (parent_.firstChild_ == element))
            parent_.firstChild_ = &this;
    }

    void insertAfter(Element* element) {
        assert(document_ == element.document_);

        parent_ = element.parent_;
        prev_ = element;
        next_ = element.next_;
        element.next_ = &this;
    }

    void detach() {
        if (parent_) {
            if (parent_.firstChild_ == &this) {
                parent_.firstChild_ = next_;
                if (next_) {
                    next_.prev_ = null;
                    next_ = null;
                } else {
                    parent_.lastChild_ = null;
                }

                assert(prev_ == null);
            } else if (parent_.lastChild_ == &this) {
                parent_.lastChild_ = prev_;
                assert(prev_);
                assert(!next_);
                prev_.next_ = null;
                prev_ = null;
            } else {
                assert(prev_);

                prev_.next_ = next_;
                if (next_) {
                    next_.prev_ = prev_;
                    next_ = null;
                }
                prev_ = null;
            }
            parent_ = null;
        }
    }

    package void detachFast() {
        if (parent_) {
            if (parent_.firstChild_ == &this) {
                parent_.firstChild_ = next_;
                if (next_) {
                    next_.prev_ = null;
                } else {
                    parent_.lastChild_ = null;
                }

                assert(prev_ == null);
            } else if (parent_.lastChild_ == &this) {
                parent_.lastChild_ = prev_;
                assert(prev_);
                assert(!next_);
                prev_.next_ = null;
            } else {
                assert(prev_);

                prev_.next_ = next_;
                if (next_) {
                    next_.prev_ = prev_;
                }
            }
        }
    }

    void destroy() {
        detachFast();
        destroyChildren();
        document_.destroyElement(&this);
    }

    void innerHTML(Appender)(ref Appender app) const {
        const(Element)* child = firstChild_;
        while (child) {
            child.outerHTML(app);
            child = child.next_;
        }
    }

    void outerHTML(Appender)(ref Appender app) const {
        if (isElement) {
            app.put('<');
            app.put(tag_);

            foreach(HTMLString attr, HTMLString value; attrs_) {
                app.put(' ');
                app.put(attr);

                if (value.length) {
                    app.put("=\"");
                    app.put(value);
                    app.put("\"");
                }
            }

            if (!isSelfClosing) {
                app.put('>');
                innerHTML(app);
                app.put("</");
                app.put(tag_);
            } else {
                app.put(" /");
            }
            app.put('>');
        } else {
            app.put(tag_);
        }
    }

    void toString(Appender)(ref Appender app) const {
        if (isElement) {
            app.put('<');
            app.put(tag_);

            foreach(HTMLString attr, HTMLString value; attrs_) {
                app.put(' ');
                app.put(attr);

                if (value.length) {
                    app.put("=\"");
                    app.put(value);
                    app.put("\"");
                }
            }
            app.put('>');
        }
    }

    auto toString() const {
        Appender!HTMLString app;
        toString(app);
        return app.data;
    }

    @property auto firstChild() const {
        const(Element)* child = firstChild_;
        while (child && !child.isElement)
            child = child.next_;

        return ElementWrapper!(const(Element))(child);
    }

    @property auto firstChild() {
        auto child = firstChild_;
        while (child && !child.isElement)
            child = child.next_;

        return ElementWrapper!Element(child);
    }

    @property auto lastChild() const {
        const(Element)* child = lastChild_;
        while (child && !child.isElement)
            child = child.prev_;
        return ElementWrapper!(const(Element))(child);
    }

    @property auto lastChild() {
        auto child = lastChild_;
        while (child && !child.isElement)
            child = child.prev_;
        return ElementWrapper!Element(child);
    }

    @property auto prevSibbling() const {
        const(Element)* sibbling = prev_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.prev_;
        return ElementWrapper!(const(Element))(sibbling);
    }

    @property auto prevSibbling() {
        auto sibbling = prev_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.prev_;
        return ElementWrapper!Element(sibbling);
    }

    @property auto nextSibbling() const {
        const(Element)* sibbling = next_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.next_;
        return ElementWrapper!(const(Element))(sibbling);
    }

    @property auto nextSibbling() {
        auto sibbling = next_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.next_;
        return ElementWrapper!Element(sibbling);
    }

    @property auto children() const {
        return ChildrenForward!(const(Element))(firstChild_);
    }

    @property auto children() {
        return ChildrenForward!(Element)(firstChild_);
    }

    @property auto attrs() const {
        return attrs_;
    }

    @property auto attrs() {
        return attrs_;
    }

    @property auto descendants() const {
        return DescendantsDFForward!(const(Element))(firstChild_);
    }

    @property auto descendants() {
        return DescendantsDFForward!(Element)(firstChild_);
    }

    @property isSelfClosing() const {
        return (flags_ & Flags.SelfClosing) != 0;
    }

    package @property isElement() const {
        return !isText;
    }

    package @property isText() const {
        return (flags_ & Flags.Text) != 0;
    }

package:
    enum Flags {
        Text        = 1 << 0,
        SelfClosing = 1 << 1,
        CDATA       = 1 << 2,
        Comment     = 1 << 3,
    }

    size_t flags_;
    HTMLString tag_; // when Text flag is set, will contain the text itself
    HTMLString[HTMLString] attrs_;

    Element* parent_;
    Element* firstChild_;
    Element* lastChild_;

    // sibblings
    Element* prev_;
    Element* next_;

    Document* document_;
}


auto createDocument(size_t options = DOMCreateOptions.Default)(const(char)[] source) {
    enum parserOptions = ((options & DOMCreateOptions.DecodeEntities) ? ParserOptions.DecodeEntities : 0);

    auto document = Document();
    document.init();

    auto builder = DOMBuilder!(Document)(document);
    parseHTML!(typeof(builder), parserOptions)(source, builder);
    if (!document.root)
        document.root(document.createElement("html"));
    return document;
}


static auto createDocument() {
    auto document = Document();
    document.init();
    document.root(document.createElement("html"));
    return document;
}


private struct Document {
    ElementWrapper!Element createElement(HTMLString tagName) {
        auto element = alloc_.alloc();
        *element = Element(&this, tagName);
        return ElementWrapper!Element(element);
    }

    ElementWrapper!Element createElement(HTMLString tagName, Element* parent) {
        auto element = createElement(tagName);
        parent.appendChild(element);
        return element;
    }

    void destroyElement(Element* element) {
        alloc_.free(element);
    }

    @property auto root() {
        return ElementWrapper!Element(root_);
    }

    @property auto root() const {
        return ElementWrapper!(const(Element))(root_);
    }

    @property auto root(Element* root) {
        root_ = root;
    }

    @property auto elements() const {
        return DescendantsDFForward!(const(Element))(root_);
    }

    @property auto elements() {
        return DescendantsDFForward!(Element)(root_);
    }

    void toString(Appender)(ref Appender app) const {
        root_.outerHTML(app);
    }

    HTMLString toString() const {
        auto app = appender!HTMLString;
        root_.outerHTML(app);
        return app.data;
    }

private:
    void init() {
        alloc_.init;
    }

    Element* root_;
    PageAllocator!(Element, 2) alloc_;
}


struct DOMBuilder(Document) {
    this(ref Document document, Element* parent = null) {
        document_ = &document;
        element_ = parent;
    }

    void onText(const(char)[] data) {
        if (data.ptr == (text_.ptr + text_.length)) {
            text_ = text_.ptr[0..text_.length + data.length];
        } else {
            text_ ~= data;
        }
    }

    void onSelfClosing() {
        element_.flags_ |= Element.Flags.SelfClosing;
        element_ = element_.parent_;
    }

    void onOpenStart(const(char)[] data) {
        auto element = document_.createElement(data);
        if (document_.root) {
            if (!text_.empty) {
                element_.appendText(text_);
                text_.length = 0;
            }
            element_.appendChild(element);
        } else {
            document_.root(element);
        }
        element_ = element;
    }

    void onOpenEnd(const(char)[] data) {
    }

    void onClose(const(char)[] data) {
        if (!text_.empty) {
            element_.appendText(text_);
            text_.length = 0;
        }
        element_ = element_.parent_;
    }

    void onAttrName(const(char)[] data) {
        attr_ = data;
        state_ = States.Attr;
    }

    void onAttrEnd() {
        if (!attr_.empty)
            element_.attr(attr_, value_);
        value_.length = 0;
        attr_.length = 0;
        state_ = States.Global;
    }

    void onAttrValue(const(char)[] data) {
        if (data.ptr == (value_.ptr + value_.length)) {
            value_ = value_.ptr[0..value_.length + data.length];
        } else {
            value_ ~= data;
        }
    }

    void onComment(const(char)[] data) {
    }

    void onDeclaration(const(char)[] data) {
    }

    void onProcessingInstruction(const(char)[] data) {
    }

    void onCDATA(const(char)[] data) {
    }

    void onDocumentEnd() {
    }

    void onNamedEntity(const(char)[] data) {
    }

    void onNumericEntity(const(char)[] data) {
    }

    void onHexEntity(const(char)[] data) {
    }

    void onEntity(const(char)[] data, const(char)[] decoded) {
        if (state_ == States.Global) {
            text_ ~= decoded;
        } else {
            value_ ~= decoded;
        }
    }

private:
    Document* document_;
    Element* element_;
    States state_;

    enum States {
        Global = 0,
        Attr,
    }

    HTMLString attr_;
    HTMLString value_;
    HTMLString text_;
}
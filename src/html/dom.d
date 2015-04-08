module html.dom;


import std.array;
import std.algorithm;
import std.ascii;
import std.conv;
import std.string;

import html.parser;
import html.alloc;


alias HTMLString = const(char)[];

enum DOMCreateOptions {
    DecodeEntities  = 1 << 0,

    Default = DecodeEntities,
}


private bool isSpace(Char)(Char ch) {
    return (ch == 32) || ((ch >= 9) && (ch <= 13));
}


private bool equalsCI(CharA, CharB)(const(CharA)[] a, const(CharB)[] b) {
    if (a.length == b.length) {
        for (uint i = 0; i < a.length; ++i) {
            if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i]))
                return false;
        }
        return true;
    }
    return false;
}


private size_t hashOf(const(char)[] x) {
    size_t hash = 5381;
    foreach(i; 0..x.length)
        hash = (hash * 33) ^ cast(size_t)x.ptr[i];
    return hash;
}


private ElementWrapper!T wrap(T)(T* element) {
    return ElementWrapper!T(element);
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

    auto front() {
        return wrap(curr_);
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
        top_ = first.parent_ ? first.parent_ : null;
    }

    bool empty() const {
        return (curr_ == null);
    }

    auto front() {
        return wrap(curr_);
    }

    void popFront() {
        while (curr_) {
            if (curr_.firstChild_) {
                curr_ = curr_.firstChild_;
            } else {
                ElementType* next = curr_.next_;
                if (!next) {
                    ElementType* parent = curr_.parent_;
                    while (parent && (top_ != parent)) {
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
    private ElementType* top_;
}


private struct QuerySelectorAll(ElementType) {
    this(Selector selector, ElementType* context) {
        selector_ = selector;
        elements_ = DescendantsDFForward!ElementType(context);
        popFront;
    }

    bool empty() const {
        return curr_ == null;
    }

    auto front() {
        return wrap(curr_);
    }

    void popFront() {
        while (!elements_.empty) {
            auto element = elements_.front;
            elements_.popFront;

            if (selector_.matches(element)) {
                curr_ = element;
                return;
            }
        }
        curr_ = null;
    }

    private ElementType* curr_;
    private DescendantsDFForward!ElementType elements_;
    private Selector selector_;
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
        element_.attr(name, value.to!string);
    }

    @property auto id() const {
        return element_.attr("id");
    }

    @property void id(T)(T value) {
        element_.attr("id", value.to!string);
    }

    auto toString() const {
        return element_ ? element_.toString() : "null";
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

    @property auto parent() const {
        return wrap(parent_);
    }

    @property auto parent() {
        return wrap(parent_);
    }

    @property auto firstChild() const {
        const(Element)* child = firstChild_;
        while (child && !child.isElement)
            child = child.next_;

        return wrap(child);
    }

    @property auto firstChild() {
        auto child = firstChild_;
        while (child && !child.isElement)
            child = child.next_;

        return wrap(child);
    }

    @property auto lastChild() const {
        const(Element)* child = lastChild_;
        while (child && !child.isElement)
            child = child.prev_;
        return wrap(child);
    }

    @property auto lastChild() {
        auto child = lastChild_;
        while (child && !child.isElement)
            child = child.prev_;
        return wrap(child);
    }

    @property auto prevSibbling() const {
        const(Element)* sibbling = prev_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.prev_;
        return wrap(sibbling);
    }

    @property auto prevSibbling() {
        auto sibbling = prev_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.prev_;
        return wrap(sibbling);
    }

    @property auto nextSibbling() const {
        const(Element)* sibbling = next_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.next_;
        return wrap(sibbling);
    }

    @property auto nextSibbling() {
        auto sibbling = next_;
        while (sibbling && !sibbling.isElement)
            sibbling = sibbling.next_;
        return wrap(sibbling);
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


auto createDocument(size_t options = DOMCreateOptions.Default)(HTMLString source) {
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
    auto createElement(HTMLString tagName) {
        auto element = alloc_.alloc();
        *element = Element(&this, tagName);
        return wrap(element);
    }

    auto createElement(HTMLString tagName, Element* parent) {
        auto element = createElement(tagName);
        parent.appendChild(element);
        return element;
    }

    void destroyElement(Element* element) {
        alloc_.free(element);
    }

    @property auto root() {
        return wrap(root_);
    }

    @property auto root() const {
        return wrap(root_);
    }

    @property auto root(Element* root) {
        root_ = root;
    }

    @property auto elements() const {
        return DescendantsDFForward!(const(Element))(root_);
    }

    @property auto elements() {
        return DescendantsDFForward!Element(root_);
    }

    ElementWrapper!Element querySelector(HTMLString selector, Element* context = null) {
        auto rules = Selector.parse(selector);
        return querySelector(rules, context);
    }

    ElementWrapper!Element querySelector(Selector selector, Element* context = null) {
        auto top = context ? context : root_;

        foreach(element; DescendantsDFForward!Element(top)) {
            if (selector.matches(element))
                return element;
        }
        return ElementWrapper!Element(null);
    }

    QuerySelectorAll!Element querySelectorAll(HTMLString selector, Element* context = null) {
        auto rules = Selector.parse(selector);
        return querySelectorAll(rules, context);
    }

    QuerySelectorAll!Element querySelectorAll(Selector selector, Element* context = null) {
        auto top = context ? context : root_;
        return QuerySelectorAll!Element(selector, top);
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

    void onText(HTMLString data) {
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

    void onOpenStart(HTMLString data) {
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

    void onOpenEnd(HTMLString data) {
    }

    void onClose(HTMLString data) {
        if (!text_.empty) {
            element_.appendText(text_);
            text_.length = 0;
        }
        element_ = element_.parent_;
    }

    void onAttrName(HTMLString data) {
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

    void onAttrValue(HTMLString data) {
        if (data.ptr == (value_.ptr + value_.length)) {
            value_ = value_.ptr[0..value_.length + data.length];
        } else {
            value_ ~= data;
        }
    }

    void onComment(HTMLString data) {
    }

    void onDeclaration(HTMLString data) {
    }

    void onProcessingInstruction(HTMLString data) {
    }

    void onCDATA(HTMLString data) {
    }

    void onDocumentEnd() {
        if (!text_.empty) {
            element_.appendText(text_);
            text_.length = 0;
        }
    }

    void onNamedEntity(HTMLString data) {
    }

    void onNumericEntity(HTMLString data) {
    }

    void onHexEntity(HTMLString data) {
    }

    void onEntity(HTMLString data, HTMLString decoded) {
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


private struct Rule {
    enum Flags : ushort {
        HasTag          = 1 << 0,
        HasAttr         = 1 << 1,
        HasPseudo       = 1 << 2,
        CaseSensitive   = 1 << 3,
        HasAny          = 1 << 4,
    }

    enum MatchType : ubyte {
        None = 0,
        Set,
        Exact,
        ContainWord,
        Contain,
        Begin,
        BeginHyphen,
        End,
    }

    enum Relation : ubyte {
        None = 0,
        Descendant,
        Child,
        DirectAdjacent,
        IndirectAdjacent,
    }

    bool matches(ElementType)(ElementType element) const {
        if (flags_ == 0)
            return false;

        if (flags_ & Flags.HasTag) {
            if (!tag_.equalsCI(element.tag))
                return false;
        }

        if (flags_ & Flags.HasAttr) {
            auto cs = (flags_ & Flags.CaseSensitive) != 0;
            final switch (match_) with (MatchType) {
            case None:
                break;
            case Set:
                if (element.attr(attr_) == null)
                    return false;
                break;
            case Exact:
                if (value_.empty) return false;
                auto attr = element.attr(attr_);
                if (!attr || (cs ? (value_ != attr) : !value_.equalsCI(attr)))
                    return false;
                break;
            case Contain:
                if (value_.empty) return false;
                auto attr = element.attr(attr_);
                if (!attr || ((attr.indexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) == -1))
                    return false;
                break;
            case ContainWord:
                if (value_.empty) return false;
                auto attr = element.attr(attr_);
                if (!attr)
                    return false;

                size_t start = 0;
                while (true) {
                    auto index = attr.indexOf(value_, start, cs ? CaseSensitive.yes : CaseSensitive.no);
                    if (index == -1)
                        return false;
                    if (index && !isSpace(attr[index - 1]))
                        return false;
                    if ((index + value_.length == attr.length) || isSpace(attr[index + value_.length]))
                        break;
                    start = index + 1;
                }
                break;
            case Begin:
                if (value_.empty) return false;
                auto attr = element.attr(attr_);
                if (!attr || ((attr.indexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) != 0))
                    return false;
                break;
            case End:
                if (value_.empty) return false;
                auto attr = element.attr(attr_);
                if (!attr || ((attr.lastIndexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) != (attr.length - value_.length)))
                    return false;
                break;
            case BeginHyphen:
                if (value_.empty) return false;
                auto attr = element.attr(attr_);
                if (!attr || ((attr.indexOf(value_, cs ? CaseSensitive.yes : CaseSensitive.no)) != 0) || ((attr.length > value_.length) && (attr[value_.length] != '-')))
                    return false;
                break;
           }
        }

        if (flags_ & Flags.HasPseudo) {
            switch (pseudo_) {
            case hashOf("checked"):
                if (!element.hasAttr("checked"))
                    return false;
                break;

            case hashOf("enabled"):
                if (element.hasAttr("disabled"))
                    return false;
                break;

            case hashOf("disabled"):
                if (!element.hasAttr("disabled"))
                    return false;
                break;

            case hashOf("empty"):
                if (element.firstChild_)
                    return false;
                break;

            case hashOf("optional"):
                if (element.hasAttr("required"))
                    return false;
                break;

            case hashOf("read-only"):
                if (!element.hasAttr("readonly"))
                    return false;
                break;

            case hashOf("read-write"):
                if (element.hasAttr("readonly"))
                    return false;
                break;

            case hashOf("required"):
                if (!element.hasAttr("required"))
                    return false;
                break;

            case hashOf("lang"):
                if (element.attr("lang") != pseudoArg_)
                    return false;
                break;

            case hashOf("first-child"):
                if (!element.parent_ || (element.parent_.firstChild != element))
                    return false;
                break;

            case hashOf("last-child"):
                if (!element.parent_ || (element.parent_.lastChild != element))
                    return false;
                break;

            case hashOf("first-of-type"):
                auto sibbling = element.prevSibbling;
                while (sibbling) {
                    if (sibbling.tag.equalsCI(element.tag))
                        return false;
                    sibbling = sibbling.prevSibbling;
                }
                break;

            case hashOf("last-of-type"):
                auto sibbling = element.nextSibbling;
                while (sibbling) {
                    if (sibbling.tag.equalsCI(element.tag))
                        return false;
                    sibbling = sibbling.nextSibbling;
                }
                break;

            case hashOf("nth-child"):
                auto ith = 1;
                auto sibbling = element.prevSibbling;
                while (sibbling) {
                    if (ith > pseudoArgNum_)
                        return false;
                    sibbling = sibbling.prevSibbling;
                    ++ith;
                }
                if (ith != pseudoArgNum_)
                    return false;
                break;

            case hashOf("nth-last-child"):
                auto ith = 1;
                auto sibbling = element.nextSibbling;
                while (sibbling) {
                    if (ith > pseudoArgNum_)
                        return false;
                    sibbling = sibbling.nextSibbling;
                    ++ith;
                }
                if (ith != pseudoArgNum_)
                    return false;
                break;

            case hashOf("nth-of-type"):
                auto ith = 1;
                auto sibbling = element.prevSibbling;
                while (sibbling) {
                    if (ith > pseudoArgNum_)
                        return false;
                    if (sibbling.tag.equalsCI(element.tag))
                        ++ith;
                    sibbling = sibbling.prevSibbling;
                }
                if (ith != pseudoArgNum_)
                    return false;
                break;

            case hashOf("nth-last-of-type"):
                auto ith = 1;
                auto sibbling = element.nextSibbling;
                while (sibbling) {
                    if (ith > pseudoArgNum_)
                        return false;
                    if (sibbling.tag.equalsCI(element.tag))
                        ++ith;
                    sibbling = sibbling.nextSibbling;
                }
                if (ith != pseudoArgNum_)
                    return false;
                break;

            case hashOf("only-of-type"):
                auto sibbling = element.prevSibbling;
                while (sibbling) {
                    if (sibbling.tag.equalsCI(element.tag))
                        return false;
                    sibbling = sibbling.prevSibbling;
                }
                sibbling = element.nextSibbling;
                while (sibbling) {
                    if (sibbling.tag.equalsCI(element.tag))
                        return false;
                    sibbling = sibbling.nextSibbling;
                }
                break;

            case hashOf("only-child"):
                if (!element.parent_ || (element.parent_.firstChild != element.parent_.lastChild))
                    return false;
                break;

            default:
                break;
            }
        }

        return true;
    }

    @property Relation relation() {
        return relation_;
    }

package:
    ushort flags_;
    MatchType match_;
    Relation relation_;
    uint pseudo_;
    HTMLString tag_;
    HTMLString attr_;
    HTMLString value_;
    HTMLString pseudoArg_;
    uint pseudoArgNum_;
}


struct Selector {
    static Selector parse(HTMLString value) {
        enum ParserStates {
            Identifier = 0,
            PostIdentifier,
            Tag,
            Class,
            ID,
            AttrName,
            AttrOp,
            PreAttrValue,
            AttrValueDQ,
            AttrValueSQ,
            AttrValueNQ,
            PostAttrValue,
            Pseudo,
            PseudoArgs,
            Relation,
        }

        value = value.strip;
        auto source = uninitializedArray!(char[])(value.length + 1);
        source[0..value.length] = value;
        source[$-1] = ' '; // add a padding space to ease parsing

        auto selector = Selector(source);
        Rule[] rules;
        rules.reserve(2);
        ++rules.length;

        auto rule = &rules.back;

        auto ptr = source.ptr;
        auto end = source.ptr + source.length;
        auto start = ptr;

        ParserStates state = ParserStates.Identifier;

        while (ptr != end) {
            final switch (state) with (ParserStates) {
            case Identifier:
                if (*ptr == '#') {
                    state = ID;
                    start = ptr + 1;
                } else if (*ptr == '.') {
                    state = Class;
                    start = ptr + 1;
                } else if (*ptr == '[') {
                    state = AttrName;
                    start = ptr + 1;
                } else if (isAlpha(*ptr)) {
                    state = Tag;
                    start = ptr;
                    continue;
                } else if (*ptr == '*') {
                    rule.flags_ |= Rule.Flags.HasAny;
                    state = PostIdentifier;
                }
                break;

            case PostIdentifier:
                switch (*ptr) {
                case '#':
                    state = ID;
                    start = ptr + 1;
                    break;
                case '.':
                    state = Class;
                    start = ptr + 1;
                    break;
                case '[':
                    state = AttrName;
                    start = ptr + 1;
                    break;
                case ':':
                    state = Pseudo;
                    if ((ptr + 1 != end) && (*(ptr + 1) == ':'))
                        ++ptr;
                    start = ptr + 1;
                    break;
                default:
                    state = Relation;
                    continue;
                }
                break;

            case Tag:
                while ((ptr != end) && isAlpha(*ptr))
                    ++ptr;
                if (ptr == end)
                    continue;
                
                rule.flags_ |= Rule.Flags.HasTag;
                rule.tag_ = start[0..ptr-start];

                state = PostIdentifier;
                continue;

            case Class:
                while ((ptr != end) && (isAlphaNum(*ptr) || (*ptr == '-') || (*ptr == '_')))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.flags_ |= Rule.Flags.HasAttr;
                rule.match_ = Rule.MatchType.ContainWord;
                rule.attr_ = "class";
                rule.value_ = start[0..ptr-start];

                state = PostIdentifier;
                break;

            case ID:
                while ((ptr != end) && (isAlphaNum(*ptr) || (*ptr == '-') || (*ptr == '_')))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.flags_ |= Rule.Flags.HasAttr;
                rule.match_ = Rule.MatchType.Exact;
                rule.attr_ = "id";
                rule.value_ = start[0..ptr-start];

                state = PostIdentifier;
                break;

            case AttrName:
                while ((ptr != end) && (isAlphaNum(*ptr) || (*ptr == '-') || (*ptr == '_')))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.flags_ |= Rule.Flags.HasAttr;
                rule.flags_ |= Rule.Flags.CaseSensitive;
                rule.attr_ = start[0..ptr-start];
                state = AttrOp;
                continue;

            case AttrOp:
                while ((ptr != end) && (isSpace(*ptr)))
                    ++ptr;
                if (ptr == end)
                    continue;

                switch (*ptr) {
                case ']':
                    rule.match_ = Rule.MatchType.Set;
                    state = PostIdentifier;
                    break;
                case '=':
                    rule.match_ = Rule.MatchType.Exact;
                    state = PreAttrValue;
                    break;
                default:
                    if ((ptr + 1 != end) && (*(ptr + 1) == '=')) {
                        switch (*ptr) {
                        case '~':
                            rule.match_ = Rule.MatchType.ContainWord;
                            break;
                        case '^':
                            rule.match_ = Rule.MatchType.Begin;
                            break;
                        case '$':
                            rule.match_ = Rule.MatchType.End;
                            break;
                        case '*':
                            rule.match_ = Rule.MatchType.Contain;
                            break;
                        case '|':
                            rule.match_ = Rule.MatchType.BeginHyphen;
                            break;
                        default:
                            rule.flags_ = 0; // error
                            ptr = end - 1;
                            break;
                        }

                        state = PreAttrValue;
                        ++ptr;
                    }
                    break;
                }
                break;

            case PreAttrValue:
                while ((ptr != end) && isSpace(*ptr))
                    ++ptr;
                if (ptr == end)
                    continue;
                
                if (*ptr == '\"') {
                    state = AttrValueDQ;
                    start = ptr + 1;
                } else if (*ptr == '\'') {
                    state = AttrValueSQ;
                    start = ptr + 1;
                } else {
                    state = AttrValueNQ;
                    start = ptr;
                }
                break;

            case AttrValueDQ:
                while ((ptr != end) && (*ptr != '\"'))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.value_ = start[0..ptr-start];
                state = PostAttrValue;
                break;

            case AttrValueSQ:
                while ((ptr != end) && (*ptr != '\''))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.value_ = start[0..ptr-start];
                state = PostAttrValue;
                break;

            case AttrValueNQ:
                while ((ptr != end) && !isSpace(*ptr) && (*ptr != ']'))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.value_ = start[0..ptr-start];
                state = PostAttrValue;
                continue;

            case PostAttrValue:
                while ((ptr != end) && (*ptr != ']') && (*ptr != 'i'))
                    ++ptr;
                if (ptr == end)
                    continue;

                if (*ptr == ']') {
                    state = PostIdentifier;
                } else if (*ptr == 'i') {
                    rule.flags_ &= ~(Rule.Flags.CaseSensitive);
                }
                break;

            case Pseudo:
                while ((ptr != end) && (isAlpha(*ptr) || (*ptr == '-')))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.pseudo_ = hashOf(start[0..ptr-start]);
                rule.flags_ |= Rule.Flags.HasPseudo;
                if (*ptr != '(') {
                    state = PostIdentifier;
                    continue;
                } else {
                    state = PseudoArgs;
                    start = ptr + 1;
                }
                break;               

            case PseudoArgs:
                while ((ptr != end) && (*ptr != ')'))
                    ++ptr;
                if (ptr == end)
                    continue;

                rule.pseudoArg_ = start[0..ptr-start];
                if (isNumeric(rule.pseudoArg_))
                    rule.pseudoArgNum_ = to!uint(rule.pseudoArg_);
                state = PostIdentifier;
                break;

            case Relation:
                while ((ptr != end) && isSpace(*ptr))
                    ++ptr;
                if (ptr == end)
                    continue;

                ++rules.length;
                rule = &rules.back;

                state = Identifier;
                switch (*ptr) {
                case '>':
                    rule.relation_ = Rule.Relation.Child;
                    break;
                case '+':
                    rule.relation_ = Rule.Relation.DirectAdjacent;
                    break;
                case '~':
                    rule.relation_ = Rule.Relation.IndirectAdjacent;
                    break;
                default:
                    rule.relation_ = Rule.Relation.Descendant;
                    continue;
                }
                break;
            }

            ++ptr;
        }

        rules.reverse();
        selector.rules_ = rules;

        return selector;
    }

    bool matches(ElementType)(ElementType element) {
        if (rules_.empty)
            return false;

        Rule.Relation relation = Rule.Relation.None;
        foreach(ref rule; rules_) {
            final switch (relation) with (Rule.Relation) {
            case None:
                if (!rule.matches(element))
                    return false;
                break;
            case Descendant:
                auto parent = element.parent_;
                if (!parent)
                    return false;

                while (parent) {
                    if (rule.matches(parent)) {
                        element = parent;
                        break;
                    }
                    parent = parent.parent_;
                }
                break;
            case Child:
                auto parent = element.parent_;
                if (!parent || !rule.matches(parent))
                    return false;
                element = parent;
                break;
            case DirectAdjacent:
                auto adjacent = element.prevSibbling;
                if (!adjacent || !rule.matches(adjacent))
                    return false;
                element = adjacent;
                break;
            case IndirectAdjacent:
                auto adjacent = element.prevSibbling;
                if (!adjacent)
                    return false;

                while (adjacent) {
                    if (rule.matches(adjacent)) {
                        element = adjacent;
                        break;
                    }
                    adjacent = adjacent.prevSibbling;
                }
                break;
            }

            relation = rule.relation;
        }
        
        return true;
    }

private:
    HTMLString source_;
    Rule[] rules_;
}
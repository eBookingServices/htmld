module html.alloc;

import core.memory : GC;
import std.algorithm;


private struct Chunk(size_t ElementSize, size_t ChunkSize = 1024, size_t Alignment = (void*).alignof) {
	static assert((Alignment & (Alignment - 1)) == 0, "alignment must be a power of two");

	enum size_t alignmentMask = Alignment - 1;
	enum size_t elementSize = (max(ElementSize, uint.sizeof) + alignmentMask) & ~alignmentMask;
	enum size_t blockSize = elementSize * ChunkSize;

	void init() {
		ptr_ = cast(ubyte*)GC.malloc(ChunkSize * elementSize, Alignment);
		foreach (i; 0..ChunkSize)
			*(cast(size_t*)&ptr_[i * elementSize]) = cast(size_t)(i + 1);
	}

	void destroy() {
		GC.free(ptr_);
	}

	void* alloc() {
		assert(!full);
		auto base = ptr_ + free_ * elementSize;
		free_ = *cast(uint*)base;
		return base;
	}

	bool owns(void* ptr) const {
		assert((cast(size_t)ptr & alignmentMask) == 0);
		return (ptr_ <= ptr) && (ptr < (ptr_ + blockSize));
	}

	void free(void* ptr) {
		assert(owns(ptr));
		*(cast(size_t*)ptr) = free_;
		free_ = (ptr - ptr_) / elementSize;
	}

	@property bool full() const {
		return free_ == ChunkSize;
	}

	private size_t free_;
	private ubyte* ptr_;
}


struct PageAllocator(Type, size_t ChunkSize = 1024) {
	alias ChunkType = Chunk!(Type.sizeof, ChunkSize, Type.alignof);

	void init() {
		auto chunk = ChunkType();
		chunk.init;
		chunks_.reserve(32);
		chunks_ ~= chunk;
		allocChunk_ = &chunks_.ptr[0];
		freeChunk_ = &chunks_.ptr[0];
	}

	Type* alloc() {
		if (!allocChunk_.full) {
			return cast(Type*)allocChunk_.alloc();
		} else {
			foreach(ref chunk; chunks_) {
				if (!chunk.full) {
					allocChunk_ = &chunk;
					return cast(Type*)allocChunk_.alloc();
				}
			}

			auto indexFreeChunk = freeChunk_ - chunks_.ptr;
			auto chunk = ChunkType();
			chunk.init;

			chunks_ ~= chunk;
			freeChunk_ = &chunks_.ptr[indexFreeChunk];
			allocChunk_ = &chunks_.ptr[chunks_.length-1];
		}
		return cast(Type*)allocChunk_.alloc();
	}

	void free(Type* ptr) {
		if (freeChunk_.owns(ptr)) {
			freeChunk_.free(ptr);
		} else {
			foreach(ref chunk; chunks_) {
				if (chunk.owns(ptr)) {
					chunk.free(ptr);
					freeChunk_ = &chunk;
					break;
				}
			}
		}
	}

	private ChunkType[] chunks_;
	private ChunkType* allocChunk_;
	private ChunkType* freeChunk_;
}

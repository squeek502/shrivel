# shrivel

A very simple [LZ77](https://en.wikipedia.org/wiki/LZ77_and_LZ78) compression algorithm that only supports ASCII text. The intention is to be easy to understand, while being sorta similar to [DEFLATE](https://en.wikipedia.org/wiki/Deflate), with no regard for compression efficiency.

The only intended use-case of this repository is to serve as a way to understand Zig's [writergate changes](https://ziglang.org/download/0.15.1/release-notes.html#Writergate). To serve that goal, there are two implementations:

- One using the 0.14.0 `GenericReader`/`GenericWriter` API (`src/old.zig`)
- One using the 0.15.1 `Reader`/`Writer` API (`src/new.zig`)

The goal is for these implementations to be as correct as possible, and to prove that correctness as best as possible (and/or find bugs in the `Reader`/`Writer` interfaces). As of now, I *think* the implementations may be correct, but proving that is still very much a work-in-progress.

Ultimately, the intention is to use this repository as a reference for an upcoming article I'm writing about the writergate changes. No ETA on that yet, though.

## An explanation of the algorithm

As mentioned previously, only ASCII text is supported (byte values from 0-127). This is because a compressed stream is read as a series of bytes, where ASCII characters are encoded verbatim, and if the most significant bit of a byte is set, then that byte encodes a "match", which has both a length (2 bits encoding the values 3-6) and a distance (5 bits encoding the values 1-32). A match essentially means "look back `<distance>` bytes in the previously decompressed data and copy `<length>` bytes starting from that position."

So, let's say you had this ASCII data:

```
a123a123
```

That could be compressed into 4 bytes like so:

```
a123<match:distance=4:len=4>
```

> [!NOTE]
> Like DEFLATE, the length of a match is allowed to extend beyond the end of the current history window. For example, `aaaa` could be compressed as `a<match:distance=1:len=3>`.

This means that, during decompression, the decompressor *must* store the most recent 32 bytes of decompressed data in order to decompress correctly. For compression, storing the most recent 32 bytes is not *mandatory*, but is necessary to achieve the maximum possible compression ratio.

## Building/testing

`build.zig` is intended to work when using Zig versions 0.14.0, 0.15.1, or latest master. It will automatically choose between `src/old.zig` and `src/new.zig` depending on the version of the compiler.

```
$ zig-0.14.0 build test
$ zig-0.15.1 build test
$ zig-master build test
```

# Poro -- A demonstration cache in Zig

A lightning-fast, key-value database written in Zig.

NOTE: This is **NOT** a production ready database, using it as such would be silly. It's an exploration of io_uring mostly, but released as a demonstration.

Built to demonstrate Zig's usefulness for databases, providing for simplicity, speed, and reliability.

## Features

- **Simple commands** - Supports SET, GET, and DEL commands
- **Persistent storage** - Write-Ahead Log (WAL) ensures data durability
- **Fast operations** - HashMap-based storage with O(1) average access time
- **Memory efficient** - Minimal memory footprint with smart allocation
- **Crash recovery** - Automatic WAL replay on startup
- **Simple architecture** - Clean, readable codebase under 200 lines

## Quick Start

### Build & Run

```bash
# Build the project
zig build

# Run the database
./zig-out/bin/poro
```

### Usage

```
Poro v1.0 - Fast key-value store
> SET mykey "Hello, World!"
OK
> GET mykey
"Hello, World!"
> DEL mykey
(integer) 1
> GET mykey
(nil)
> QUIT
```

## Commands

| Command | Description | Example |
|---------|-------------|---------|
| `SET key value` | Store a key-value pair | `SET name "Alice"` |
| `GET key` | Retrieve value by key | `GET name` |
| `DEL key` | Delete a key | `DEL name` |
| `QUIT` | Exit the database | `QUIT` |

## Architecture

Poro consists of three core components:

### 1. Simple Store (`simple_store.zig`)
- HashMap-based key-value storage
- Automatic memory management
- Integration with WAL for persistence

### 2. Write-Ahead Log (`simple_wal.zig`)
- Ensures data durability
- Supports crash recovery
- Sequential file-based storage

### 3. CLI Interface (`main.zig`)
- Simple command parsing
- Interactive prompt
- Error handling and user feedback

## Performance

Poro delivers exceptional performance through its optimized architecture:

### Benchmark Results

- **Peak throughput**: 1.19M keys/sec (100k small keys)
- **Small data** (8-16 bytes): ~1M keys/sec, sub-microsecond latency
- **Medium data** (32-128 bytes): ~680K keys/sec, ~1.5 microsecond latency
- **Large data** (1KB values): ~227K keys/sec, ~4.4 microsecond latency

### Architecture Optimizations

- **O(1)** average time complexity for SET/GET/DEL operations
- **Custom hash table** - Linear probing with Wyhash for minimal collisions
- **io_uring WAL** - 10MB ring buffer with asynchronous disk I/O
- **Static allocator** - State machine-controlled memory management
- **Small binary size** - Typically under 1MB

## Data Persistence

All operations are logged to a Write-Ahead Log (`poro.wal`) for durability:

1. **Write Operation** → Log to WAL → Update in-memory store
2. **Recovery** → Replay WAL entries → Rebuild in-memory state

## Building from Source

### Requirements

- Zig 0.14.1 or later
- Linux/macOS/Windows

### Build Commands

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run the application
zig build run
```

## Testing

```bash
# Run all tests
zig build test

# Manual testing
echo -e "SET test hello\\nGET test\\nDEL test\\nQUIT" | ./zig-out/bin/poro
```

## File Structure

```
src/
├── main.zig           # CLI interface and main entry point
├── simple_store.zig   # Key-value store implementation
├── simple_wal.zig     # Write-Ahead Log implementation
└── root.zig          # Library exports
```

## Configuration

Poro uses sensible defaults with no configuration required:

- **WAL file**: `poro.wal` (created automatically)
- **Buffer size**: 1KB for command input
- **HashMap**: Default Zig HashMap with string keys

## Error Handling

Poro provides clear error messages for common issues:

- Missing keys or values
- Invalid commands
- I/O errors
- Memory allocation failures

## Limitations

- **Single-threaded** - No concurrent access support
- **Memory-bound** - All data kept in RAM
- **Basic commands** - Only SET/GET/DEL operations
- **No networking** - CLI interface only

## License

Copyright 2025 Jeremy Tregunna

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

[https://www.apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

## Why Poro?

Poro means "small" in several languages, reflecting our philosophy:

- **Small codebase** - Easy to understand and modify
- **Small binary** - Minimal deployment footprint
- **Small dependencies** - Only Zig standard library
- **Big performance** - Despite being small, it's fast!

---

Built with ❤️ in Zig

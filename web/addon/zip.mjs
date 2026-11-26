// A zip file (deflate) from memory, with fixed timestamps, so that the same files give the same bytes. Enough for
// the extension packages (pack-addon.mjs); no zip64, no directories.
import { crc32, deflateRawSync } from "node:zlib";

const UTF8 = 0x0800, DEFLATE = 8, VERSION = 20, DATE = 0x0021; // 1980-01-01

/** `files`: [{ name, data }] with "/" in names. */
export function zip(files) {
  const bodies = [], entries = [];
  let offset = 0;
  for (const { name, data } of files) {
    const path = Buffer.from(name, "utf8"), packed = deflateRawSync(data, { level: 9 });
    // the part both headers share: flags, method, time, date, checksum, sizes, name and extra lengths
    const shared = Buffer.alloc(24);
    [UTF8, DEFLATE, 0, DATE].forEach((v, i) => shared.writeUInt16LE(v, i * 2));
    shared.writeUInt32LE(crc32(data), 8);
    shared.writeUInt32LE(packed.length, 12);
    shared.writeUInt32LE(data.length, 16);
    shared.writeUInt16LE(path.length, 20);
    const local = Buffer.alloc(6);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(VERSION, 4);
    bodies.push(local, shared, path, packed);
    const central = Buffer.alloc(8), tail = Buffer.alloc(14); // comment, disk, attributes, offset
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(VERSION, 4);
    central.writeUInt16LE(VERSION, 6);
    tail.writeUInt32LE(offset, 10);
    entries.push(central, shared, tail, path);
    offset += local.length + shared.length + path.length + packed.length;
  }
  const directory = Buffer.concat(entries);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...bodies, directory, end]);
}

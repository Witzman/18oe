// Modules build-addon.mjs puts together.
declare module "oe:geometry" {
  const geometry: import("../render/mapdata.ts").MapGeometry;
  export default geometry;
}
declare module "oe:fonts" {
  const fonts: { family: string; weight: string; style: string; unicodeRange: string; data: string }[];
  export default fonts;
}

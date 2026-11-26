// Modules build-addon.mjs puts together.
declare module "oe:market-css" {
  const css: string;
  export default css;
}
declare module "oe:fonts" {
  const fonts: { family: string; weight: string; style: string; unicodeRange: string; data: string }[];
  export default fonts;
}

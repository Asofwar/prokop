// steal from https://github.com/sindresorhus/pretty-bytes/blob/master/index.js
export function prettyBytes(n: number) {
  const UNITS = [
    _('B'),
    _('KB'),
    _('MB'),
    _('GB'),
    _('TB'),
    _('PB'),
    _('EB'),
    _('ZB'),
    _('YB'),
  ];

  if (n < 1000) {
    return n + ' ' + UNITS[0];
  }
  const exponent = Math.min(Math.floor(Math.log10(n) / 3), UNITS.length - 1);
  n = Number((n / Math.pow(1000, exponent)).toPrecision(3));
  const unit = UNITS[exponent];
  return n + ' ' + unit;
}

// A transfer rate such as "4.2 MB/s", with the "/s" suffix localized too.
export function prettyBytesRate(n: number) {
  return _('%s/s').replace('%s', prettyBytes(n));
}

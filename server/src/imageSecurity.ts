import { Buffer } from 'node:buffer';
import sharp from 'sharp';

const MAX_AVATAR_INPUT_BYTES = 256 * 1024;
const MAX_AVATAR_PIXELS = 16 * 1024 * 1024;
const AVATAR_EDGE_PIXELS = 1024;

export class InvalidAvatarError extends Error {}

export async function sanitizeAvatarBase64(value: string): Promise<Buffer> {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length % 4 !== 0) {
    throw new InvalidAvatarError('头像数据格式无效');
  }
  const input = Buffer.from(value, 'base64');
  if (!input.length || input.length > MAX_AVATAR_INPUT_BYTES) {
    throw new InvalidAvatarError('头像大小不能超过 256KB');
  }
  try {
    const image = sharp(input, {
      failOn: 'error',
      limitInputPixels: MAX_AVATAR_PIXELS,
      sequentialRead: true
    });
    const metadata = await image.metadata();
    if (
      !metadata.width
      || !metadata.height
      || metadata.width * metadata.height > MAX_AVATAR_PIXELS
      || !new Set(['jpeg', 'png', 'webp']).has(metadata.format || '')
    ) {
      throw new InvalidAvatarError('头像图片格式或尺寸无效');
    }
    const output = await image
      .rotate()
      .resize({
        width: AVATAR_EDGE_PIXELS,
        height: AVATAR_EDGE_PIXELS,
        fit: 'inside',
        withoutEnlargement: true
      })
      .jpeg({ quality: 86, mozjpeg: true })
      .toBuffer();
    if (!output.length || output.length > MAX_AVATAR_INPUT_BYTES) {
      throw new InvalidAvatarError('头像处理后仍然过大');
    }
    return output;
  } catch (error) {
    if (error instanceof InvalidAvatarError) throw error;
    throw new InvalidAvatarError('头像不是有效的 JPEG、PNG 或 WebP 图片');
  }
}

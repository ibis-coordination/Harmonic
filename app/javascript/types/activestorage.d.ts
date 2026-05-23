declare module "@rails/activestorage" {
  export class DirectUpload {
    id: number
    file: File
    url: string
    delegate?: DirectUploadDelegate

    constructor(file: File, url: string, delegate?: DirectUploadDelegate)

    create(
      callback: (error: Error | null, blob: DirectUploadBlob) => void,
    ): void
  }

  export interface DirectUploadDelegate {
    directUploadWillCreateBlobWithXHR?(xhr: XMLHttpRequest): void
    directUploadWillStoreFileWithXHR?(xhr: XMLHttpRequest): void
  }

  export interface DirectUploadBlob {
    id: number
    key: string
    signed_id: string
    filename: string
    content_type: string
    byte_size: number
    checksum: string
  }

  export function start(): void
}

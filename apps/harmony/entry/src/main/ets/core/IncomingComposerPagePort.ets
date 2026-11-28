import { ComposerDocument } from './messages/ComposerDocument';
import { IncomingComposerDocuments } from './incoming-share/IncomingComposerDraftBridge';
import { IncomingShareDestination } from './incoming-share/IncomingShareStore';

/** Keeps page lifecycle checks in the page and durable merge semantics in the bridge. */
export class IncomingComposerPagePort implements IncomingComposerDocuments {
  reader: (target: IncomingShareDestination) => Promise<ComposerDocument>;
  writer: (target: IncomingShareDestination, expected: string, value: ComposerDocument) => Promise<boolean>;
  constructor(reader: (target: IncomingShareDestination) => Promise<ComposerDocument>,
    writer: (target: IncomingShareDestination, expected: string, value: ComposerDocument) => Promise<boolean>) {
    this.reader = reader; this.writer = writer;
  }
  read(target: IncomingShareDestination): Promise<ComposerDocument> { return this.reader(target); }
  compareAndSave(target: IncomingShareDestination, expected: string, value: ComposerDocument): Promise<boolean> {
    return this.writer(target, expected, value);
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:phoneopia_mobile/models/models.dart';

void main() {
  test('Nearby attachment survives a local history round trip', () {
    final original = Message(id: -123, conversationId: -42, senderId: 42,
      type: 'file', fileName: 'notes.pdf', localPath: '/private/nearby_files/notes.pdf',
      createdAt: DateTime.utc(2026, 9, 8), status: 'sent_nearby');
    final restored = Message.fromJson(original.toJson());
    expect(restored.localPath, original.localPath);
    expect(restored.conversationId, -42);
    expect(restored.status, 'sent_nearby');
    expect(restored.fileName, 'notes.pdf');
  });
  test('Existing server messages do not require a local path', () {
    final message = Message.fromJson({'id': 1, 'conversation_id': 2,
      'sender_id': 3, 'type': 'text', 'content': 'hello', 'status': 'read'});
    expect(message.localPath, isNull);
    expect(message.content, 'hello');
    expect(message.status, 'read');
  });
  test('Migrating an offline conversation retains attachment and timestamp', () {
    final original = Message(id: -9, conversationId: -42, senderId: 42,
      type: 'image', localPath: '/private/photo.jpg', createdAt: DateTime.utc(2026,9,8),
      status: 'sent_nearby');
    final migrated = Message.fromJson({...original.toJson(), 'conversation_id': 321});
    expect(migrated.conversationId, 321);
    expect(migrated.localPath, original.localPath);
    expect(migrated.createdAt.isAtSameMomentAs(original.createdAt), isTrue);
    expect(migrated.id, original.id);
  });
}

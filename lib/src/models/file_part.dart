final class FilePart {
  final int number;
  final int? size;

  const FilePart({required this.number, this.size});

  factory FilePart.fromJson(Map<String, dynamic> json) {
    return FilePart(
      number: json['number'] as int,
      size: json['size'] as int?,
    );
  }
}

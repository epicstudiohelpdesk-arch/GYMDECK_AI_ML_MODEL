class Food {
  final String id;
  final String name;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final double quantity;
  final String? imageUrl;
  final DateTime timestamp;

  const Food({
    required this.id,
    required this.name,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.quantity,
    this.imageUrl,
    required this.timestamp,
  });

  Food copyWith({
    String? name,
    double? calories,
    double? protein,
    double? carbs,
    double? fat,
    double? quantity,
    String? imageUrl,
    DateTime? timestamp,
  }) {
    return Food(
      id: id,
      name: name ?? this.name,
      calories: calories ?? this.calories,
      protein: protein ?? this.protein,
      carbs: carbs ?? this.carbs,
      fat: fat ?? this.fat,
      quantity: quantity ?? this.quantity,
      imageUrl: imageUrl ?? this.imageUrl,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}


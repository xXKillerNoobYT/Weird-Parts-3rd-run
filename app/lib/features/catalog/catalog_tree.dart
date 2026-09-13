import '../../data/app_database.dart';

/// Shop walk: Category → Type → Variant → (general part or Brand) → Variance.
enum CatalogTreeKind {
  category,
  type,
  variant,
  part,
  brand,
  variance,
  unassigned,
}

class CatalogTreeSnapshot {
  const CatalogTreeSnapshot({
    required this.categories,
    required this.styles,
    required this.types,
    required this.parts,
    required this.brands,
    required this.brandVersions,
  });

  final List<Category> categories;
  final List<Style> styles;
  final List<Type> types;
  final List<Part> parts;
  final List<Brand> brands;
  final List<BrandVersion> brandVersions;
}

class CatalogTreeNode {
  const CatalogTreeNode({
    required this.kind,
    required this.id,
    required this.label,
    this.subtitle,
    this.children = const [],
    this.partId,
    this.brandVersionId,
    this.brandId,
    this.categoryId,
    this.styleId,
    this.typeId,
    this.searchText = '',
  });

  final CatalogTreeKind kind;
  final String id;
  final String label;
  final String? subtitle;
  final List<CatalogTreeNode> children;
  final String? partId;
  final String? brandVersionId;
  final String? brandId;
  final String? categoryId;
  final String? styleId;
  final String? typeId;
  final String searchText;

  bool get isJobPickable =>
      kind == CatalogTreeKind.part || kind == CatalogTreeKind.variance;

  bool get canExpand =>
      kind == CatalogTreeKind.category ||
      kind == CatalogTreeKind.type ||
      kind == CatalogTreeKind.variant ||
      kind == CatalogTreeKind.part ||
      kind == CatalogTreeKind.brand ||
      kind == CatalogTreeKind.unassigned;

  bool matches(String query) {
    final q = query.toLowerCase();
    return label.toLowerCase().contains(q) ||
        (subtitle?.toLowerCase().contains(q) ?? false) ||
        searchText.toLowerCase().contains(q);
  }

  CatalogTreeNode copyWith({List<CatalogTreeNode>? children}) {
    return CatalogTreeNode(
      kind: kind,
      id: id,
      label: label,
      subtitle: subtitle,
      children: children ?? this.children,
      partId: partId,
      brandVersionId: brandVersionId,
      brandId: brandId,
      categoryId: categoryId,
      styleId: styleId,
      typeId: typeId,
      searchText: searchText,
    );
  }
}

Future<CatalogTreeSnapshot> loadCatalogTreeSnapshot(
  AppDatabase db, {
  bool activeOnly = false,
}) async {
  return CatalogTreeSnapshot(
    categories: await db.taxonomyDao.listCategories(),
    styles: await db.taxonomyDao.listStyles(),
    types: await db.taxonomyDao.listTypes(),
    parts: await db.partsDao.listParts(activeOnly: activeOnly),
    brands: await db.taxonomyDao.listBrands(),
    brandVersions: await db.partsDao.listAllBrandVersions(),
  );
}

/// One tree for Catalog and the Types listing. Edit once — both views update.
List<CatalogTreeNode> buildCatalogTree(CatalogTreeSnapshot snap) {
  final brandNames = {for (final b in snap.brands) b.id: b.name};
  final stylesByCategory = <String, List<Style>>{};
  for (final s in snap.styles) {
    stylesByCategory.putIfAbsent(s.categoryId, () => []).add(s);
  }
  final typesByStyle = <String, List<Type>>{};
  for (final t in snap.types) {
    typesByStyle.putIfAbsent(t.styleId, () => []).add(t);
  }
  final versionsByPart = <String, List<BrandVersion>>{};
  for (final v in snap.brandVersions) {
    versionsByPart.putIfAbsent(v.partId, () => []).add(v);
  }

  final assigned = <String>{};
  final roots = <CatalogTreeNode>[];

  for (final category in snap.categories) {
    final typeNodes = <CatalogTreeNode>[];
    for (final style in stylesByCategory[category.id] ?? const <Style>[]) {
      final variantNodes = <CatalogTreeNode>[];
      for (final variant in typesByStyle[style.id] ?? const <Type>[]) {
        final hanging = snap.parts
            .where((p) => p.typeId == variant.id)
            .map((p) {
              assigned.add(p.id);
              return _partNode(
                p,
                versionsByPart[p.id] ?? const [],
                brandNames,
                categoryId: category.id,
                styleId: style.id,
                typeId: variant.id,
              );
            })
            .toList(growable: false);
        variantNodes.add(
          CatalogTreeNode(
            kind: CatalogTreeKind.variant,
            id: variant.id,
            label: variant.name,
            subtitle: 'Variant',
            categoryId: category.id,
            styleId: style.id,
            typeId: variant.id,
            children: hanging,
          ),
        );
      }
      for (final p in snap.parts.where(
        (p) => p.styleId == style.id && p.typeId == null,
      )) {
        assigned.add(p.id);
        variantNodes.add(
          _partNode(
            p,
            versionsByPart[p.id] ?? const [],
            brandNames,
            categoryId: category.id,
            styleId: style.id,
          ),
        );
      }
      typeNodes.add(
        CatalogTreeNode(
          kind: CatalogTreeKind.type,
          id: style.id,
          label: style.name,
          subtitle: 'Type',
          categoryId: category.id,
          styleId: style.id,
          children: variantNodes,
        ),
      );
    }
    for (final p in snap.parts.where(
      (p) => p.categoryId == category.id && p.styleId == null,
    )) {
      assigned.add(p.id);
      typeNodes.add(
        _partNode(
          p,
          versionsByPart[p.id] ?? const [],
          brandNames,
          categoryId: category.id,
        ),
      );
    }
    roots.add(
      CatalogTreeNode(
        kind: CatalogTreeKind.category,
        id: category.id,
        label: category.name,
        subtitle: 'Category',
        categoryId: category.id,
        children: typeNodes,
      ),
    );
  }

  final loose = snap.parts.where((p) => !assigned.contains(p.id)).map((p) {
    return _partNode(
      p,
      versionsByPart[p.id] ?? const [],
      brandNames,
    );
  }).toList(growable: false);
  if (loose.isNotEmpty) {
    roots.add(
      CatalogTreeNode(
        kind: CatalogTreeKind.unassigned,
        id: 'unassigned',
        label: 'Unassigned',
        subtitle: 'No category',
        children: loose,
      ),
    );
  }
  return roots;
}

CatalogTreeNode _partNode(
  Part part,
  List<BrandVersion> versions,
  Map<String, String> brandNames, {
  String? categoryId,
  String? styleId,
  String? typeId,
}) {
  final byBrand = <String, List<BrandVersion>>{};
  for (final v in versions) {
    byBrand.putIfAbsent(v.brandId, () => []).add(v);
  }
  final brandNodes = <CatalogTreeNode>[];
  final brandIds = byBrand.keys.toList()
    ..sort((a, b) => (brandNames[a] ?? a).compareTo(brandNames[b] ?? b));
  for (final brandId in brandIds) {
    final rows = List<BrandVersion>.of(byBrand[brandId]!)
      ..sort((a, b) {
        if (a.isMain != b.isMain) return a.isMain ? -1 : 1;
        final byName = a.varianceName.compareTo(b.varianceName);
        if (byName != 0) return byName;
        return a.mpn.compareTo(b.mpn);
      });
    final brandName = brandNames[brandId] ?? 'Unknown brand';
    brandNodes.add(
      CatalogTreeNode(
        kind: CatalogTreeKind.brand,
        id: '$brandId:${part.id}',
        label: brandName,
        subtitle: 'Brand',
        partId: part.id,
        brandId: brandId,
        categoryId: categoryId,
        styleId: styleId,
        typeId: typeId,
        searchText: brandName,
        children: [
          for (final v in rows)
            CatalogTreeNode(
              kind: CatalogTreeKind.variance,
              id: v.id,
              label: _varianceLabel(v),
              subtitle: v.isMain ? 'Main' : 'Option',
              partId: part.id,
              brandVersionId: v.id,
              brandId: brandId,
              categoryId: categoryId,
              styleId: styleId,
              typeId: typeId,
              searchText: '${v.varianceName} ${v.mpn} $brandName',
            ),
        ],
      ),
    );
  }

  final bits = <String>[
    if (part.uom.isNotEmpty) part.uom,
    if (!part.active) 'Inactive',
    if (versions.isEmpty) 'General',
  ];
  return CatalogTreeNode(
    kind: CatalogTreeKind.part,
    id: part.id,
    label: part.name,
    subtitle: bits.isEmpty ? null : bits.join(' · '),
    partId: part.id,
    categoryId: categoryId ?? part.categoryId,
    styleId: styleId ?? part.styleId,
    typeId: typeId ?? part.typeId,
    searchText: '${part.description} ${part.keywords}',
    children: brandNodes,
  );
}

String _varianceLabel(BrandVersion v) {
  final name = v.varianceName.trim();
  if (name.isEmpty) return v.mpn;
  return '$name · ${v.mpn}';
}

List<CatalogTreeNode> filterCatalogTree(
  List<CatalogTreeNode> nodes,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return nodes;
  return [
    for (final n in nodes) ?_filterNode(n, q),
  ];
}

CatalogTreeNode? _filterNode(CatalogTreeNode node, String query) {
  if (node.matches(query)) return node;
  final kids = [
    for (final c in node.children) ?_filterNode(c, query),
  ];
  if (kids.isEmpty) return null;
  return node.copyWith(children: kids);
}

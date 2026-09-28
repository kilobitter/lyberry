import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/photo_source.dart';
import 'package:lyberry/state/item_draft.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/decoded_image_size.dart';
import 'package:lyberry/ui/library_scope.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/screens/cover_crop_screen.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/rating_input.dart';

/// Manual add/edit form. Every fetched field from a later phase stays editable
/// here, and this screen is the guaranteed path when scanning is unavailable.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.existing, this.prefill, this.coverUrl});

  final MediaItem? existing;

  /// Prefilled draft, for example from a chosen metadata candidate.
  final ItemDraft? prefill;

  /// Cover art to fetch after the first frame; failure is harmless.
  final String? coverUrl;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final ItemDraft _draft;
  late final TextEditingController _title;
  late final TextEditingController _creator;
  late final TextEditingController _year;
  late final TextEditingController _publisher;
  late final TextEditingController _barcode;
  late final TextEditingController _description;
  late final TextEditingController _platform;
  late final TextEditingController _review;
  late final TextEditingController _notes;

  final Map<String, MediaAsset> _newAssets = <String, MediaAsset>{};
  List<String> _photoIds = <String>[];
  String? _coverId;
  Map<String, String> _errors = <String, String>{};
  bool _saving = false;
  bool _recoveredLoaded = false;
  bool _coverRequested = false;
  String? _pendingCoverUrl;
  int _coverRequestSeq = 0;
  int _coverChoiceGeneration = 0;
  bool _photoBusy = false;
  bool _disposed = false;
  bool _leaving = false;

  /// Any in-flight photo, camera, crop or save operation. Every control that
  /// could conflict with one, and every handler that could start one, checks
  /// this so two operations can never overlap.
  bool get _mediaBusy => _photoBusy || _saving;

  /// True while this editor is still alive: mounted, not disposed, and no back
  /// navigation has been handled. Safe across awaits, including while the crop
  /// route sits on top of the editor.
  bool get _draftAlive => mounted && !_disposed && !_leaving;

  /// True only while the editor is still the route the user is looking at, so a
  /// deferred source load can never push the crop screen over another route.
  bool get _editorIsTop {
    if (!_draftAlive) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _draft = existing == null
        ? (widget.prefill ?? ItemDraft(medium: MediaType.book, title: ''))
        : ItemDraft.fromItem(existing);
    _title = TextEditingController(text: _draft.title);
    _creator = TextEditingController(text: _draft.creator);
    _year = TextEditingController(text: _draft.yearText);
    _publisher = TextEditingController(text: _draft.publisher);
    _barcode = TextEditingController(text: _draft.barcode);
    _description = TextEditingController(text: _draft.description);
    _platform = TextEditingController(text: _draft.platform);
    _review = TextEditingController(text: _draft.review);
    _notes = TextEditingController(text: _draft.notes);
    _photoIds = List<String>.of(_draft.photoAssetIds);
    _coverId = _draft.coverAssetId;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_recoveredLoaded) return;
    _recoveredLoaded = true;
    if (!_coverRequested) {
      _coverRequested = true;
      final url = widget.coverUrl;
      if (url != null && url.isNotEmpty) unawaited(_fetchCover(url));
    }
    final controller = LibraryScope.of(context);
    final recovered = controller.takeRecoveredPhotos();
    if (recovered.isEmpty) return;
    _adoptRecoveredPhotos(controller, recovered);
  }

  /// Downloads cover art for a chosen candidate. A failure leaves the medium
  /// placeholder in place and never blocks saving.
  Future<void> _fetchCover(String url) async {
    final requestId = ++_coverRequestSeq;
    final generation = _coverChoiceGeneration;
    final services = AppServicesScope.of(context);
    final asset = await services.covers.download(url);
    if (!mounted || _disposed || asset == null) return;
    // A slow download must never replace a newer choice: the user may have
    // removed the cover, picked another photo or chosen a different candidate.
    if (requestId != _coverRequestSeq || generation != _coverChoiceGeneration) {
      return;
    }
    setState(() {
      _newAssets[asset.id] = asset;
      _coverId = asset.id;
    });
  }

  /// Recovered photos come from a previous, possibly killed session, so they are
  /// validated, deduplicated and capped before they reach the draft. Nothing
  /// here may throw during build.
  void _adoptRecoveredPhotos(
    LibraryController controller,
    List<PickedPhoto> recovered,
  ) {
    var added = 0;
    var unreadable = 0;
    var skipped = 0;
    for (final photo in recovered) {
      final MediaAsset asset;
      try {
        asset = controller.buildPhotoAsset(photo);
      } on Object {
        unreadable++;
        continue;
      }
      if (_photoIds.contains(asset.id) || _newAssets.containsKey(asset.id)) {
        skipped++;
        continue;
      }
      if (_photoIds.length >= FieldLimits.maxPhotos) {
        skipped++;
        continue;
      }
      _newAssets[asset.id] = asset;
      _photoIds.add(asset.id);
      added++;
    }
    _reportRecovery(added: added, unreadable: unreadable, skipped: skipped);
  }

  void _reportRecovery({
    required int added,
    required int unreadable,
    required int skipped,
  }) {
    final parts = <String>[
      if (added > 0) 'Recovered $added photo(s) from the last session.',
      if (unreadable > 0) '$unreadable recovered photo(s) could not be read.',
      if (skipped > 0) '$skipped recovered photo(s) were skipped.',
    ];
    if (parts.isEmpty) return;
    final message = parts.join(' ');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showMessage(context, message);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final controller in <TextEditingController>[
      _title,
      _creator,
      _year,
      _publisher,
      _barcode,
      _description,
      _platform,
      _review,
      _notes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // Once a back is handled this draft is gone: a deferred capture, crop
        // or save must neither adopt into it nor pop another route.
        if (didPop) _leaving = true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isEditing ? 'Edit copy' : 'New copy'),
          actions: <Widget>[
            IconButton(
              key: const Key('editor-save'),
              tooltip: 'Save copy',
              onPressed: _mediaBusy ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            LyberryMetrics.gutter,
            8,
            LyberryMetrics.gutter,
            24,
          ),
          children: <Widget>[
            _label('Medium'),
            _mediumChoices(),
            const SizedBox(height: 18),
            _field(
              key: const Key('field-title'),
              label: 'Title',
              controller: _title,
              required: true,
              error: _errors['title'],
              textInputAction: TextInputAction.next,
            ),
            _field(
              key: const Key('field-creator'),
              label: 'Creator',
              controller: _creator,
              textInputAction: TextInputAction.next,
            ),
            _field(
              key: const Key('field-year'),
              label: 'Year',
              controller: _year,
              error: _errors['year'],
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              textInputAction: TextInputAction.next,
            ),
            _field(
              key: const Key('field-publisher'),
              label: 'Publisher',
              controller: _publisher,
              textInputAction: TextInputAction.next,
            ),
            _field(
              key: const Key('field-barcode'),
              label: 'Barcode / ISBN',
              controller: _barcode,
              error: _errors['barcode'],
              helper: 'Optional. ISBN-10/13, EAN-8/13 or UPC-A.',
              textInputAction: TextInputAction.next,
              suffix: IconButton(
                key: const Key('field-barcode-lookup'),
                tooltip: 'Look up this code',
                onPressed: _mediaBusy ? null : _lookupBarcode,
                icon: const Icon(Icons.search, size: 18),
                color: LyberryColors.muted,
              ),
            ),
            _field(
              key: const Key('field-description'),
              label: 'Description',
              controller: _description,
              maxLines: 3,
            ),
            if (_draft.medium.hasPlatform)
              _field(
                key: const Key('field-platform'),
                label: 'Platform',
                controller: _platform,
                helper: 'Console or system, for example PlayStation 5.',
                textInputAction: TextInputAction.next,
              ),
            const SizedBox(height: 6),
            _label('Rating'),
            RatingInput(
              rating: _draft.rating,
              onChanged: (value) => setState(() => _draft.rating = value),
            ),
            if (_errors['rating'] != null) _errorText(_errors['rating']!),
            // Personal, per-copy state. Books and films only; a medium change
            // hides the control but keeps whatever is stored on the draft.
            if (_draft.medium.isFinishable) ...<Widget>[
              const SizedBox(height: 4),
              CheckboxListTile(
                key: const Key('field-finished'),
                value: _draft.isFinished,
                onChanged: _saving
                    ? null
                    : (value) =>
                          setState(() => _draft.isFinished = value ?? false),
                title: Text('Finished', style: LyberryType.body),
                subtitle: Text(
                  'Mark this copy once you have finished it.',
                  style: LyberryType.bodyMuted,
                ),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: LyberryColors.signal,
              ),
            ],
            const SizedBox(height: 12),
            _field(
              key: const Key('field-review'),
              label: 'Review',
              controller: _review,
              maxLines: 3,
            ),
            _field(
              key: const Key('field-notes'),
              label: 'Notes',
              controller: _notes,
              helper: 'Private notes. Included when you export a backup.',
              maxLines: 3,
            ),
            const SizedBox(height: 6),
            _label('Cover'),
            _coverRow(),
            const SizedBox(height: 18),
            _label('Photos'),
            _photoActions(),
            const SizedBox(height: 8),
            Text(
              '${_photoIds.length} of ${FieldLimits.maxPhotos} photos',
              style: LyberryType.bodyMuted,
            ),
            const SizedBox(height: 10),
            _photoGrid(),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              LyberryMetrics.gutter,
              8,
              LyberryMetrics.gutter,
              12,
            ),
            child: FilledButton(
              key: const Key('editor-save-bottom'),
              onPressed: _mediaBusy ? null : _save,
              child: Text(isEditing ? 'Save changes' : 'Add to collection'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(), style: LyberryType.eyebrow()),
  );

  Widget _mediumChoices() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final medium in MediaType.values)
          ChoiceChip(
            key: Key('medium-${medium.wireValue}'),
            label: Text(medium.label),
            selected: _draft.medium == medium,
            onSelected: (_) => _selectMedium(medium),
          ),
      ],
    );
  }

  void _selectMedium(MediaType medium) {
    setState(() {
      _draft.medium = medium;
      if (!medium.hasPlatform) {
        _platform.clear();
        _draft.platform = '';
      }
    });
  }

  Widget _field({
    required Key key,
    required String label,
    required TextEditingController controller,
    String? error,
    String? helper,
    bool required = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    TextInputAction? textInputAction,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        key: key,
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        textInputAction: textInputAction,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          helperText: helper,
          helperStyle: LyberryType.bodyMuted,
          errorText: error,
          suffixIcon: suffix,
        ),
      ),
    );
  }

  /// Looks the typed barcode up and folds a chosen candidate into the form.
  Future<void> _lookupBarcode() async {
    if (_mediaBusy) return;
    final identifier = IdentifierNormalizer.tryNormalize(_barcode.text);
    if (identifier == null) {
      showMessage(context, 'Enter a valid ISBN or barcode first.');
      return;
    }
    final choice = await Navigator.of(context).push<LookupChoice>(
      MaterialPageRoute<LookupChoice>(
        builder: (_) => CandidatesScreen(
          query: LookupQuery(identifier: identifier, mediumHint: _draft.medium),
        ),
      ),
    );
    if (!mounted || choice is! UseCandidate) return;
    final candidate = choice.candidate;
    setState(() {
      if (candidate.title.trim().isNotEmpty) _title.text = candidate.title;
      if (candidate.creator.trim().isNotEmpty) {
        _creator.text = candidate.creator;
      }
      if (candidate.publisher.trim().isNotEmpty) {
        _publisher.text = candidate.publisher;
      }
      if (candidate.description.trim().isNotEmpty) {
        _description.text = candidate.description;
      }
      if (candidate.platform.trim().isNotEmpty) {
        _platform.text = candidate.platform;
      }
      final year = candidate.year;
      if (year != null) _year.text = '$year';
      final medium = candidate.medium;
      if (medium != null) _draft.medium = medium;
      _draft.source = MediaSource(
        providerId: candidate.providerId,
        externalId: candidate.externalId,
        url: candidate.sourceUrl ?? '',
      );
      _pendingCoverUrl = candidate.coverUrl;
      // Invalidate any cover download still in flight for the previous choice.
      _coverChoiceGeneration++;
    });
    final coverUrl = _pendingCoverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      await _fetchCover(coverUrl);
    }
  }

  Widget _errorText(String message) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      message,
      style: const TextStyle(color: LyberryColors.signal, fontSize: 12),
    ),
  );

  Widget _coverRow() {
    final coverId = _coverId;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 84,
          height: 84,
          child: _thumbnail(coverId, isCover: true),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                key: const Key('cover-camera'),
                onPressed: _mediaBusy
                    ? null
                    : () => _setCover(PhotoOrigin.camera),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('Camera'),
              ),
              OutlinedButton.icon(
                key: const Key('cover-library'),
                onPressed: _mediaBusy
                    ? null
                    : () => _setCover(PhotoOrigin.library),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Library'),
              ),
              if (coverId != null)
                TextButton(
                  key: const Key('cover-remove'),
                  onPressed: _mediaBusy
                      ? null
                      : () => setState(() {
                          _coverChoiceGeneration++;
                          _coverId = null;
                        }),
                  child: const Text('Remove cover'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoActions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        OutlinedButton.icon(
          key: const Key('photo-camera'),
          onPressed: _mediaBusy ? null : () => _addPhoto(PhotoOrigin.camera),
          icon: const Icon(Icons.photo_camera_outlined, size: 18),
          label: const Text('Take photo'),
        ),
        OutlinedButton.icon(
          key: const Key('photo-library'),
          onPressed: _mediaBusy ? null : () => _addPhoto(PhotoOrigin.library),
          icon: const Icon(Icons.photo_library_outlined, size: 18),
          label: const Text('Choose photo'),
        ),
      ],
    );
  }

  Widget _photoGrid() {
    if (_photoIds.isEmpty) {
      return Text(
        'No photos yet.',
        key: const Key('editor-photos-empty'),
        style: LyberryType.bodyMuted,
      );
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (final id in _photoIds)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  SizedBox(width: 88, height: 88, child: _thumbnail(id)),
                  Positioned(
                    top: -8,
                    right: -8,
                    child: _RemovePhotoButton(
                      key: Key('photo-remove-$id'),
                      onTap: _mediaBusy ? null : () => _removePhoto(id),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              TextButton.icon(
                key: Key('photo-cover-$id'),
                onPressed: _mediaBusy ? null : () => _usePhotoAsCover(id),
                icon: const Icon(Icons.crop, size: 16),
                label: const Text('Use as cover'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  // A real 48dp target, still visually compact.
                  minimumSize: const Size(0, LyberryMetrics.touchTarget),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  // Standard density: a compact density would shave the 48dp
                  // minimum back down to 40 on desktop-class platforms.
                  visualDensity: VisualDensity.standard,
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// Shows a stored image, a not-yet-saved image, or a neutral placeholder.
  Widget _thumbnail(String? id, {bool isCover = false}) {
    if (id == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: LyberryColors.surface,
          border: Border.all(color: LyberryColors.rule),
          borderRadius: BorderRadius.circular(LyberryMetrics.corner),
        ),
        child: Center(
          child: Icon(
            isCover ? Icons.image_outlined : Icons.photo_outlined,
            color: LyberryColors.muted,
            size: 20,
          ),
        ),
      );
    }
    final pending = _newAssets[id];
    if (pending != null) return _image(pending.bytes);
    return FutureBuilder<MediaAsset?>(
      future: LibraryScope.of(context).asset(id),
      builder: (context, snapshot) {
        final bytes = snapshot.data?.bytes;
        if (bytes == null) return _thumbnail(null, isCover: isCover);
        return _image(bytes);
      },
    );
  }

  Widget _image(Uint8List bytes) => ClipRRect(
    borderRadius: BorderRadius.circular(LyberryMetrics.corner),
    child: Image.memory(
      bytes,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      cacheWidth: decodedImageWidth(context, 96),
    ),
  );

  Future<void> _addPhoto(PhotoOrigin origin) async {
    if (_mediaBusy) return;
    if (_photoIds.length >= FieldLimits.maxPhotos) {
      showMessage(
        context,
        'A copy can hold at most ${FieldLimits.maxPhotos} photos.',
      );
      return;
    }
    final controller = LibraryScope.of(context);
    setState(() => _photoBusy = true);
    try {
      final asset = await controller.capturePhoto(origin);
      if (asset == null || !mounted || !_draftAlive) return;
      // The cap is re-checked at adoption time, not only before capture.
      if (_photoIds.length >= FieldLimits.maxPhotos) {
        showMessage(
          context,
          'A copy can hold at most ${FieldLimits.maxPhotos} photos.',
        );
        return;
      }
      if (_photoIds.contains(asset.id)) {
        showMessage(context, 'That photo is already on this copy.');
        return;
      }
      setState(() {
        _newAssets[asset.id] = asset;
        _photoIds.add(asset.id);
      });
    } on Object catch (error) {
      if (mounted) showMessage(context, describeFailure(error));
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  /// Cover Camera/Library and every "Use as cover" action share this preview.
  ///
  /// The caller claims the choice generation before it starts loading or
  /// capturing, so a slow provider cover that lands while the user is waiting
  /// for their own source, or while they are cropping, is discarded. A new
  /// source captured here is kept as a personal photo too, deduplicated by
  /// reference and capped.
  Future<void> _openCoverCrop(
    Uint8List sourceBytes, {
    MediaAsset? newSource,
    required int generation,
  }) async {
    // A deferred source load must never push the crop screen over whatever the
    // user is looking at now.
    if (!_editorIsTop) return;
    final transform = AppServicesScope.of(context).images;
    final asset = await Navigator.of(context).push<MediaAsset>(
      MaterialPageRoute<MediaAsset>(
        builder: (_) =>
            CoverCropScreen(sourceBytes: sourceBytes, transform: transform),
      ),
    );
    if (asset == null || !_draftAlive) return;
    if (generation != _coverChoiceGeneration) return;
    setState(() {
      _newAssets[asset.id] = asset;
      _coverId = asset.id;
      final source = newSource;
      // Dedupe on the photo reference, never on asset presence: an original
      // picked, removed and picked again must come back, and a source whose
      // bytes happen to match the derived cover still belongs in the list.
      if (source != null &&
          !_photoIds.contains(source.id) &&
          _photoIds.length < FieldLimits.maxPhotos) {
        _newAssets[source.id] = source;
        _photoIds.add(source.id);
      }
    });
  }

  /// Crops one of the copy's own photos. The stored original stays untouched.
  Future<void> _usePhotoAsCover(String id) async {
    if (_mediaBusy || !_editorIsTop) return;
    // Manual intent is claimed now, before the bytes are even loaded.
    final generation = ++_coverChoiceGeneration;
    setState(() => _photoBusy = true);
    try {
      final bytes = await _photoBytes(id);
      if (!mounted || !_draftAlive) return;
      if (bytes == null) {
        showMessage(context, 'That photo could not be opened.');
        return;
      }
      await _openCoverCrop(bytes, generation: generation);
    } on Object catch (error) {
      if (mounted) showMessage(context, describeFailure(error));
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<Uint8List?> _photoBytes(String id) async {
    final pending = _newAssets[id];
    if (pending != null) return pending.bytes;
    final asset = await LibraryScope.of(context).asset(id);
    return asset?.bytes;
  }

  Future<void> _setCover(PhotoOrigin origin) async {
    if (_mediaBusy || !_editorIsTop) return;
    if (_photoIds.length >= FieldLimits.maxPhotos) {
      // Explain before opening the camera, and offer the photos already there.
      await _explainPhotoLimit();
      return;
    }
    final controller = LibraryScope.of(context);
    // Claim the manual choice before the camera or picker opens.
    final generation = ++_coverChoiceGeneration;
    setState(() => _photoBusy = true);
    try {
      final asset = await controller.capturePhoto(origin);
      if (asset == null || !_draftAlive) return;
      await _openCoverCrop(
        asset.bytes,
        newSource: asset,
        generation: generation,
      );
    } on Object catch (error) {
      if (mounted) showMessage(context, describeFailure(error));
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _explainPhotoLimit() async {
    final chooseExisting = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('All 20 photos are used'),
        content: const Text(
          'This copy already holds the maximum number of personal photos. '
          'You can use one of the existing photos as its cover instead.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('cover-limit-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('cover-limit-existing'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Choose existing'),
          ),
        ],
      ),
    );
    if (chooseExisting == true && mounted) await _chooseExistingForCover();
  }

  Future<void> _chooseExistingForCover() async {
    if (_photoIds.isEmpty) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose a photo'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final id in _photoIds)
                  InkWell(
                    key: Key('cover-existing-$id'),
                    onTap: () => Navigator.of(dialogContext).pop(id),
                    child: SizedBox(
                      width: 72,
                      height: 72,
                      child: _thumbnail(id),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (chosen != null && mounted) await _usePhotoAsCover(chosen);
  }

  void _removePhoto(String id) {
    if (_mediaBusy) return;
    // A derived cover references its own asset, so removing the photo
    // reference must leave the cover alone.
    setState(() => _photoIds.remove(id));
  }

  Future<void> _save() async {
    if (_mediaBusy) return;
    final controller = LibraryScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _errors = <String, String>{};
    });

    _syncDraft();
    // Only assets the saved copy still references: an abandoned intermediate
    // cover render between two crop attempts must not be written.
    final referenced = <String>{?_coverId, ..._photoIds};
    final assets = <MediaAsset>[
      for (final entry in _newAssets.entries)
        if (referenced.contains(entry.key)) entry.value,
    ];
    final existing = widget.existing;
    try {
      if (existing == null) {
        await controller.createItem(_draft, assets: assets);
      } else {
        await controller.updateItem(existing, _draft, assets: assets);
      }
      if (!_draftAlive) {
        // The user left the editor while the write was in flight: report the
        // outcome, but never pop whatever route is on top now.
        _announce(
          messenger,
          existing == null ? 'Copy added.' : 'Copy updated.',
        );
        return;
      }
      navigator.pop();
      _announce(messenger, existing == null ? 'Copy added.' : 'Copy updated.');
    } on ValidationException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errors = <String, String>{
          for (final issue in error.issues) issue.field: issue.message,
        };
      });
      showMessage(context, error.issues.first.message);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showMessage(context, describeFailure(error));
    }
  }

  void _syncDraft() {
    _draft
      ..title = _title.text
      ..creator = _creator.text
      ..publisher = _publisher.text
      ..description = _description.text
      ..platform = _platform.text
      ..yearText = _year.text
      ..barcode = _barcode.text
      ..review = _review.text
      ..notes = _notes.text
      ..coverAssetId = _coverId
      ..photoAssetIds = List<String>.of(_photoIds);
  }

  void _announce(ScaffoldMessengerState messenger, String message) {
    if (!messenger.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Small glyph, full 48dp hit target.
class _RemovePhotoButton extends StatelessWidget {
  const _RemovePhotoButton({super.key, required this.onTap});

  /// Null while a photo, crop or save operation owns the editor.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: LyberryMetrics.touchTarget,
      height: LyberryMetrics.touchTarget,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: 'Remove photo',
        child: IgnorePointer(
          ignoring: onTap == null,
          child: Tooltip(
            message: 'Remove photo',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: LyberryColors.background,
                    shape: BoxShape.circle,
                    border: Border.all(color: LyberryColors.rule),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(Icons.close, size: 14),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

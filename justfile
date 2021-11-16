sync:
	cd ../markdown_editor && flutter build web
	cp -r ../markdown_editor/build/web/* ./

sync:
	cd ../markdown_editor && just build-web --base-href "/md-edit/"
	cp -r ../markdown_editor/build/web/* ./md-edit

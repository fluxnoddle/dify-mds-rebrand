// MDS - Metadata Solutions company footer for the signin page.
// Content is intentionally hardcoded in Vietnamese (company contact info,
// not user-facing translatable copy), so it is not routed through i18n.
const MdsFooter = () => {
  return (
    <footer className="mt-auto flex w-full flex-col items-center gap-1 border-t border-divider-subtle px-6 py-6 text-center">
      <p className="text-xs text-text-tertiary">
        Văn phòng: 224A Điện Biên Phủ, Phường Xuân Hòa, TP. Hồ Chí Minh
      </p>
      <p className="text-xs text-text-tertiary">
        Email:
        {' '}
        <a
          href="mailto:admin.department@metasolutions.software"
          className="text-text-accent hover:underline"
        >
          admin.department@metasolutions.software
        </a>
      </p>
      <p className="text-xs text-text-tertiary">
        Hotline:
        {' '}
        <a
          href="tel:+84962618093"
          className="text-text-accent hover:underline"
        >
          096 261 8093
        </a>
      </p>
      <p className="mt-1 text-xs text-text-quaternary">
        © 2025 MDS - Metadata Solutions. All rights reserved.
      </p>
    </footer>
  )
}

export default MdsFooter
